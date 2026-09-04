//
//  AppState.swift
//  MotionLandmarker
//
//  画面の状態。カメラ・サイドカー・パイプラインをまとめて持つ。
//

import AppKit
import Foundation
import Observation

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
    var statusMessage: String?

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
        didSet { UserDefaults.standard.set(outputRoot.path, forKey: Self.outputRootDefaultsKey) }
    }
    var isDefaultOutputRoot: Bool { outputRoot.standardizedFileURL == Self.defaultOutputRoot.standardizedFileURL }

    @ObservationIgnored private var client: LandmarkerClient?
    @ObservationIgnored private var pipeline: LandmarkPipeline?
    @ObservationIgnored private var fpsWindow: [TimeInterval] = []

    var isReady: Bool { sidecarState == .ready && camera.isCameraAvailable }

    func start() {
        guard client == nil else { return }
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

    private func launch(uv: URL, project: URL) {
        let client = LandmarkerClient()
        let pipeline = LandmarkPipeline(client: client)
        pipeline.setDrawOptions(drawOptions)
        client.onReady = { Task { @MainActor in self.sidecarState = .ready } }
        client.onExit = { code, log in
            Task { @MainActor in
                self.sidecarState = .failed("推論プロセスが終了しました (code \(code))\n\(log.suffix(600))")
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
        guard let pipeline, isReady else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let stem = "live_" + f.string(from: Date())
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
            statusMessage = "保存先: \(url.path)"
        }
    }

    func resetOutputRoot() {
        guard !isRecording else { return }
        outputRoot = Self.defaultOutputRoot
        statusMessage = "保存先を既定に戻しました: \(outputRoot.path)"
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
