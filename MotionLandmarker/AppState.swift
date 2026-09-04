//
//  AppState.swift
//  MotionLandmarker
//
//  画面の状態。カメラ・サイドカー・パイプラインをまとめて持つ。
//

import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState {
    enum SidecarState: Equatable {
        case idle, preparing(String), ready, failed(String)
    }

    var sidecarState: SidecarState = .idle
    var drawOptions = DrawOptions() {
        didSet { pipeline?.setDrawOptions(drawOptions) }
    }
    /// 波形の表示モード（上半身 / 手腕）。次回起動時も保持する。
    var metricMode: MetricMode = MetricMode(rawValue: UserDefaults.standard.string(forKey: "metricMode") ?? "") ?? .upperBody {
        didSet { UserDefaults.standard.set(metricMode.rawValue, forKey: "metricMode") }
    }
    /// 非表示にしたグラフと系列（モードをまたいで保持する）
    var hiddenCharts: Set<String> = []
    var hiddenMetrics: Set<MetricKind> = []
    var displayImage: CGImage?
    /// 10 秒分の表示に十分な長さ（60 fps でも 600 サンプル = 10 秒）
    var history = MetricHistory(capacity: 600)
    var inferenceFPS: Double = 0
    var isRecording = false
    var recordedFrames = 0
    var lastOverlayURL: URL?
    var lastOutputRoot: URL?
    /// 映像エリアで再生中の動画。nil ならカメラ映像を表示する。
    var playbackURL: URL? {
        didSet { setUpPlayback() }
    }
    /// 再生用プレイヤー（playbackURL に対応）
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    /// 再生中の録画の指標時系列（同じ録画の CSV から読む）。無ければ nil
    var playbackTimeline: PlaybackTimeline?
    /// 動画の再生位置（秒）
    var playbackSeconds: Double = 0
    var playbackHasWaveform: Bool { !(playbackTimeline?.isEmpty ?? true) }

    /// 動画ファイルの処理中か
    var isImporting = false
    var importProgress: (done: Int, total: Int) = (0, 0)
    var importName = ""
    /// 処理スレッドから読むため，メインアクタ外でも安全なフラグにする
    @ObservationIgnored private let importCancel = CancelFlag()

    private func setUpPlayback() {
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        playbackTimeline = nil
        playbackSeconds = 0
        guard let url = playbackURL else { return }
        let p = AVPlayer(url: url)
        player = p
        // 波形は同じ録画の CSV から復元する（別スレッドで読む）
        Task.detached { [url] in
            let t = PlaybackTimeline.load(forVideo: url)
            await MainActor.run { if self.playbackURL == url { self.playbackTimeline = t } }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
            Task { @MainActor in self.playbackSeconds = time.seconds.isFinite ? time.seconds : 0 }
        }
        p.play()
    }
    var statusMessage: String?
    /// 推論プロセスが終了したときの標準エラー出力（原因調査用）
    var sidecarExitLog: String = ""

    let camera = CameraManager()

    /// 既定の出力先
    static let defaultOutputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/MotionLandmarker/results_data", isDirectory: true)
    static let outputRootDefaultsKey = "outputRoot"

    /// 録画の出力先。「保存先…」で変更でき，UserDefaults に保持する。
    var outputRoot: URL = {
        if let saved = UserDefaults.standard.string(forKey: AppState.outputRootDefaultsKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return AppState.defaultOutputRoot
    }() {
        didSet {
            UserDefaults.standard.set(outputRoot.path, forKey: Self.outputRootDefaultsKey)
            refreshLastRecording()
        }
    }

    /// 保存先にある最新の overlay 動画を Play の対象にする（起動直後や保存先の変更後）
    func refreshLastRecording() {
        let dir = outputRoot.appendingPathComponent("video_overlay")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            lastOverlayURL = nil
            return
        }
        let latest = items
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        lastOverlayURL = latest
        if playbackURL != nil, latest == nil { playbackURL = nil }
    }
    var isDefaultOutputRoot: Bool { outputRoot.standardizedFileURL == Self.defaultOutputRoot.standardizedFileURL }

    @ObservationIgnored private var client: LandmarkerClient?
    @ObservationIgnored private var pipeline: LandmarkPipeline?
    @ObservationIgnored private var fpsWindow: [TimeInterval] = []

    var isReady: Bool { sidecarState == .ready && camera.isCameraAvailable }

    func start() {
        guard client == nil else { return }
        refreshLastRecording()
        camera.start()
        sidecarState = .preparing("サイドカーを準備中…")
        Task.detached { [self] in
            do {
                guard let uv = SidecarBootstrap.locateUV() else { throw SidecarError.uvNotFound }
                let project = try SidecarBootstrap.prepareProject()
                await MainActor.run { self.sidecarState = .preparing("Python 依存関係を同期中（初回は数十秒）…") }
                try SidecarBootstrap.sync(uv: uv, project: project)
                await MainActor.run { self.launch(uv: uv, project: project) }
            } catch {
                await MainActor.run { self.sidecarState = .failed(error.localizedDescription) }
            }
        }
    }

    /// 推論プロセスを起動し直す（落ちたとき用）
    func restartSidecar() {
        guard !isRecording, !isImporting else { return }
        client?.stop()
        client = nil
        pipeline = nil
        sidecarState = .idle
        start()
    }

    /// 推論プロセスの終了ログをダイアログで表示する
    func showSidecarLog() {
        let alert = NSAlert()
        alert.messageText = "推論プロセスのログ"
        alert.informativeText = sidecarExitLog.isEmpty ? "（ログはありません）" : String(sidecarExitLog.suffix(3000))
        alert.addButton(withTitle: "閉じる")
        alert.addButton(withTitle: "ログをコピー")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sidecarExitLog, forType: .string)
        }
    }

    private func launch(uv: URL, project: URL) {
        let client = LandmarkerClient()
        let pipeline = LandmarkPipeline(client: client)
        pipeline.setDrawOptions(drawOptions)
        client.onReady = { Task { @MainActor in self.sidecarState = .ready } }
        client.onExit = { code, log in
            Task { @MainActor in
                self.sidecarExitLog = log
                self.sidecarState = .failed("推論プロセスが終了しました (code \(code))．「ログ」で詳細を表示")
            }
        }
        pipeline.onFrame = { image, _, metrics, recorded in
            Task { @MainActor in self.receive(image: image, metrics: metrics, recorded: recorded) }
        }
        camera.onFrame = { pb, ms in pipeline.handleCameraFrame(pb, ms) }
        do {
            try client.start(uv: uv, project: project)
            sidecarState = .preparing("MediaPipe モデルを読み込み中…")
            self.client = client
            self.pipeline = pipeline
        } catch {
            sidecarState = .failed(error.localizedDescription)
        }
    }

    private func receive(image: CGImage?, metrics: [MetricKind: Double], recorded: Int) {
        displayImage = image
        recordedFrames = recorded
        history.push(metrics)
        let now = Date().timeIntervalSince1970
        fpsWindow.append(now)
        fpsWindow.removeAll { $0 < now - 2 }
        inferenceFPS = Double(fpsWindow.count) / 2
    }

    // MARK: - 録画

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard let pipeline, isReady, !isImporting else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let stem = "live_" + f.string(from: Date())
        playbackURL = nil
        do {
            try pipeline.startRecording(outputRoot: outputRoot, stem: stem)
            isRecording = true
            recordedFrames = 0
            statusMessage = nil
        } catch {
            statusMessage = "録画を開始できません: \(error.localizedDescription)"
        }
    }

    private func stopRecording(completion: (@MainActor () -> Void)? = nil) {
        isRecording = false
        guard let pipeline else { completion?(); return }
        pipeline.stopRecording { recorder, error in
            Task { @MainActor in
                if let error {
                    self.statusMessage = "録画の保存に失敗: \(error.localizedDescription)"
                } else if let recorder {
                    self.lastOverlayURL = recorder.overlayURL
                    self.lastOutputRoot = self.outputRoot
                    var msg = "\(recorder.frameCount) フレームを保存: \(self.outputRoot.path)"
                    if recorder.skippedVideoFrames > 0 {
                        msg += "（動画に書けなかったフレーム \(recorder.skippedVideoFrames)）"
                    }
                    self.statusMessage = msg
                }
                completion?()
            }
        }
    }

    /// 直前の録画（overlay 動画）を映像エリアで再生する。再生中なら止めてカメラ映像に戻す。
    func togglePlayback() {
        if playbackURL != nil {
            playbackURL = nil
        } else if let url = lastOverlayURL, !isRecording {
            playbackURL = url
        }
    }

    // MARK: - 動画ファイルの読み込み

    /// 動画を選んで処理し，完了したら overlay 動画と波形を再生する
    func importVideo() {
        guard let pipeline, isReady, !isRecording, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "処理する動画を選ぶ"
        panel.message = "動画のランドマークを抽出し，保存先に CSV / JSON / 動画3種を生成します"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.prompt = "処理"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        playbackURL = nil
        isImporting = true
        importCancel.reset()
        importName = url.lastPathComponent
        importProgress = (0, 0)
        statusMessage = nil
        pipeline.setCameraPaused(true)
        let outputRoot = self.outputRoot
        Task.detached { [self] in
            let result = Result {
                try VideoImporter.run(videoURL: url, outputRoot: outputRoot, pipeline: pipeline,
                                      progress: { done, total in
                                          Task { @MainActor in self.importProgress = (done, total) }
                                      },
                                      isCancelled: { [importCancel] in importCancel.isCancelled })
            }
            await MainActor.run { self.finishImport(result) }
        }
    }

    func cancelImport() { importCancel.cancel() }

    private func finishImport(_ result: Result<VideoImporter.Result, Error>) {
        pipeline?.setCameraPaused(false)
        isImporting = false
        switch result {
        case .success(let r):
            var msg = "\(importName) を処理しました（\(r.frames) フレーム）→ \(outputRoot.path)"
            if r.skippedVideoFrames > 0 { msg += "（動画に書けなかったフレーム \(r.skippedVideoFrames)）" }
            statusMessage = msg
            lastOverlayURL = r.overlayURL
            lastOutputRoot = outputRoot
            playbackURL = r.overlayURL   // 生成した overlay 動画と波形を再生
        case .failure(let e):
            var msg = "動画の処理に失敗: \(e.localizedDescription)"
            if case .failed = sidecarState { msg += "（推論プロセスが終了しました．上部の「ログ」で詳細を確認）" }
            statusMessage = msg
            refreshLastRecording()
        }
    }

    /// 過去の録画をファイル選択ダイアログで選んで映像エリアで再生する
    func openRecordingForPlayback() {
        guard !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "再生する録画を選ぶ"
        panel.message = "再生する動画（overlay / raw / skeleton）を選んでください"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        let overlayDir = outputRoot.appendingPathComponent("video_overlay")
        panel.directoryURL = FileManager.default.fileExists(atPath: overlayDir.path) ? overlayDir : outputRoot
        panel.prompt = "再生"
        if panel.runModal() == .OK, let url = panel.url {
            playbackURL = url
        }
    }

    func revealOutput() {
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([lastOverlayURL ?? outputRoot])
    }

    /// フォルダ選択ダイアログで出力先を変える。録画中は変更しない。
    func chooseOutputRoot() {
        guard !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "録画の保存先"
        panel.message = "CSV / JSON / 動画を保存するフォルダを選んでください（この中に results_data の構成で保存されます）"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputRoot
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url
            // 保存先はボタン列の下に常時表示しているため，ここでは重ねて出さない
            statusMessage = nil
        }
    }

    func resetOutputRoot() {
        guard !isRecording else { return }
        outputRoot = Self.defaultOutputRoot
        statusMessage = nil
    }

    /// 終了処理。録画中なら書き出し完了後に completion を呼ぶ。
    func shutdown(completion: @escaping @MainActor () -> Void) {
        camera.stop()
        let finish: @MainActor () -> Void = { [self] in
            client?.stop()
            completion()
        }
        if isRecording { stopRecording(completion: finish) } else { finish() }
    }
}

/// スレッド間で共有する中止フラグ
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}
