//
//  ContentView.swift
//  MotionLandmarker
//

import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.uiScale) private var uiScale
    /// ライブ映像を左右反転して表示する（鏡のように見せる）。表示だけで，録画・CSV には影響しない
    @AppStorage("mirrorLive") private var mirrorLive = false

    /// 映像部分の高さ。仕切りをドラッグして変え，次回起動時も保持する。
    /// ドラッグ中は `draggingHeight` だけを動かし（UserDefaults への書き込みを避ける），終了時に保存する。
    @AppStorage("videoHeight") private var savedVideoHeight: Double = 360
    @State private var draggingHeight: Double?
    @State private var dragStartHeight: Double?
    private let videoHeightRange: ClosedRange<Double> = 160...1080
    private var videoHeight: Double { draggingHeight ?? savedVideoHeight }
    /// 映像エリアの大きさが変わったときに人物タイルの縦横比を合わせ直す処理（変化が止まるまで待つ）
    @State private var tileAspectTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            cameraSection
                .frame(height: videoHeight)
            if state.playbackURL != nil {
                transportBar
            }
            statusRow
            resizeHandle
            graphSection
                .frame(minHeight: 200)
        }
        // 上部バーの左右を同じ幅にして Record / Play を中央に置くので，窓の最小幅はその合計より狭くしない
        .frame(minWidth: max(900, barMinWidth), minHeight: 600)
    }

    /// 上部バーの左（設定）・中央（Record / Play）・右（ボタン群）の幅（文字の倍率や表示の切り替えで変わる）
    @State private var barWidths = BarWidths()
    private let barSpacing: CGFloat = 12
    private let barPadding: CGFloat = 12
    /// 上部バーが中央揃えを保てる最小幅（左右は広い方の幅にそろえる）
    private var barMinWidth: CGFloat {
        2 * max(barWidths.left, barWidths.right) + barWidths.center + 2 * barSpacing + 2 * barPadding
    }

    /// 再生バー：再生 / 一時停止，コマ送り，シークバー，時刻。映像を非表示にしていても操作できる
    /// チェックボックス列の幅（グラフ表示部分と再生バーの左端を揃えるため）。
    /// 列とグラフの境目を左右にドラッグして変え，次回起動時も保持する
    @AppStorage("checkboxColumnWidth") private var savedColumnWidth: Double = 270
    @State private var draggingColumnWidth: Double?
    @State private var columnDragStart: Double?
    private let columnWidthRange: ClosedRange<Double> = 160...600
    private var checkboxColumnWidth: CGFloat { CGFloat(draggingColumnWidth ?? savedColumnWidth) * uiScale }

    /// 再生時のグラフの横軸の表示範囲（動画の秒）。nil なら全体
    @State private var zoomRange: ClosedRange<Double>?
    @State private var magnifyStartRange: ClosedRange<Double>?
    @State private var graphsFrame: CGRect = .zero
    @State private var scrollMonitor: Any?
    /// プロット領域の左右の余白（外側 16 + 枠内 12 + 縦軸ラベル 48 + 隙間 ≈ 84 / 右 28）
    private let plotLeftInset: CGFloat = 84
    private let plotRightInset: CGFloat = 28

    /// 表示範囲（動画の秒）。ズームしていなければ全体
    private var visibleRange: ClosedRange<Double> {
        zoomRange ?? 0...max(0.001, state.playbackDuration)
    }

    /// グラフ領域の x 座標（ローカル）→ 動画の秒
    private func seconds(atX x: CGFloat) -> Double {
        let w = max(1, graphsFrame.width - plotLeftInset - plotRightInset)
        let f = Double(min(max((x - plotLeftInset) / w, 0), 1))
        let r = visibleRange
        return r.lowerBound + (r.upperBound - r.lowerBound) * f
    }

    /// `anchor` 秒を固定して `factor` 倍に拡大（>1）/ 縮小（<1）
    private func zoom(by factor: Double, anchor: Double) {
        let r = visibleRange
        let full = max(0.001, state.playbackDuration)
        var span = (r.upperBound - r.lowerBound) / factor
        span = min(max(span, 0.2), full)          // 最小 0.2 秒，最大は全体
        let f = (anchor - r.lowerBound) / max(0.001, r.upperBound - r.lowerBound)
        var lower = anchor - span * f
        lower = min(max(lower, 0), full - span)
        zoomRange = span >= full ? nil : lower...(lower + span)
    }

    /// 表示範囲を秒数だけ左右に動かす
    private func pan(by seconds: Double) {
        guard let r = zoomRange else { return }
        let full = max(0.001, state.playbackDuration)
        let span = r.upperBound - r.lowerBound
        let lower = min(max(r.lowerBound + seconds, 0), full - span)
        zoomRange = lower...(lower + span)
    }

    /// 再生位置が表示範囲から外れたら範囲を追従させる
    private func followPlayback() {
        guard let r = zoomRange else { return }
        let t = state.playbackSeconds
        if t < r.lowerBound || t > r.upperBound {
            let span = r.upperBound - r.lowerBound
            let full = max(0.001, state.playbackDuration)
            let lower = min(max(t, 0), max(0, full - span))
            zoomRange = lower...(lower + span)
        }
    }

    /// マウスホイール / トラックパッドのスクロールでズーム（上下）と移動（左右）
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard state.playbackURL != nil, let window = event.window,
                  let contentView = window.contentView else { return event }
            // ウィンドウ座標（左下原点）→ 画面上の位置と graphsFrame（グローバル，左上原点）を比べる
            let p = event.locationInWindow
            let flippedY = contentView.bounds.height - p.y
            let local = CGPoint(x: p.x - graphsFrame.minX, y: flippedY - graphsFrame.minY)
            guard local.x >= 0, local.y >= 0, local.x <= graphsFrame.width, local.y <= graphsFrame.height else { return event }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if abs(dy) > abs(dx) {
                // 上下：カーソル位置を中心に拡大縮小
                let factor = exp(Double(dy) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
                zoom(by: factor, anchor: seconds(atX: local.x))
            } else if dx != 0, zoomRange != nil {
                // 左右：表示範囲を移動（1 画面幅 = 表示範囲の秒数）
                let span = visibleRange.upperBound - visibleRange.lowerBound
                let w = max(1, graphsFrame.width - plotLeftInset - plotRightInset)
                pan(by: -Double(dx) / Double(w) * span)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }

    /// チェックボックス列とグラフの境目。左右にドラッグするとグラフの横幅が変わる
    private var columnResizeHandle: some View {
        ZStack {
            Rectangle().fill(Color(NSColor.separatorColor)).frame(width: 1)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 48)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if columnDragStart == nil { columnDragStart = savedColumnWidth }
                    let w = (columnDragStart ?? savedColumnWidth) + g.translation.width
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        draggingColumnWidth = min(max(w, columnWidthRange.lowerBound), columnWidthRange.upperBound)
                    }
                }
                .onEnded { _ in
                    if let w = draggingColumnWidth { savedColumnWidth = w }
                    draggingColumnWidth = nil
                    columnDragStart = nil
                }
        )
        .help("ドラッグしてグラフの横幅を調整")
    }

    private var transportBar: some View {
        HStack(spacing: 0) {
            // 左：チェックボックス列と同じ幅に，ボタンと時刻をまとめる
            HStack(spacing: 12) {
                Button { state.step(frames: -1) } label: { Image(systemName: "backward.frame") }
                    .help("1 フレーム戻る")
                Button { state.togglePlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").frame(width: 34)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("再生 / 一時停止（スペース）")
                Button { state.step(frames: 1) } label: { Image(systemName: "forward.frame") }
                    .help("1 フレーム進む")
                // 時刻は 2 段にして列幅（270px）に収める
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.timeString(state.playbackSeconds))
                    Text(Self.timeString(state.playbackDuration)).foregroundStyle(.secondary)
                }
                .font(.title2).monospacedDigit()
            }
            .font(.system(size: 32 * uiScale))
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(width: checkboxColumnWidth + 12, alignment: .leading)
            // 右：シークバーをグラフ表示部分と同じ横幅（グラフの枠と同じ余白）にする
            Slider(value: Binding(get: { state.playbackSeconds },
                                  set: { state.seek(to: $0) }),
                   in: 0...max(0.001, state.playbackDuration))
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private static func timeString(_ s: Double) -> String {
        let t = max(0, s)
        let m = Int(t) / 60, sec = Int(t) % 60, cs = Int((t - floor(t)) * 100)
        return String(format: "%d:%02d.%02d", m, sec, cs)
    }

    /// 映像とグラフの間の仕切り。上下にドラッグすると映像の高さが変わる。
    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(Color(NSColor.separatorColor)).frame(height: 1)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 48, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if dragStartHeight == nil { dragStartHeight = savedVideoHeight }
                    let h = (dragStartHeight ?? savedVideoHeight) + g.translation.height
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        draggingHeight = min(max(h, videoHeightRange.lowerBound), videoHeightRange.upperBound)
                    }
                }
                .onEnded { _ in
                    if let h = draggingHeight { savedVideoHeight = h }
                    draggingHeight = nil
                    dragStartHeight = nil
                }
        )
        .help("ドラッグして映像の高さを調整")
    }

    // MARK: - カメラ映像＋ランドマーク（アスペクト比を保って可変サイズ）
    private var cameraSection: some View {
        VStack(spacing: 6) {
            // 表示設定バー：左から 人数モード｜表示の切り替え（2×2）｜描く部位とミラー（2 行），
            // 中央に Record / Play，右端にファイル操作のボタン。
            // Record / Play を常にバー全体の中央に置くため，左右の領域を同じ幅（広い方）にする（BarLayout）
            BarLayout(spacing: barSpacing) {
                HStack(alignment: .center, spacing: barSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("人数").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Picker("人数", selection: $state.personMode) {
                                ForEach(AppState.PersonMode.allCases) { m in Text(m.label).tag(m) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 130 * uiScale)
                            .disabled(state.isRecording || state.isImporting || state.isSwitchingPersonMode)
                            .help("1人: Holistic（1人専用）/ 複数人: 人物ごとに切り出して Holistic を適用し最大5人．映像は全体＋1人ずつのタイル，グラフは選んだ人．CSV は画面中央の人")
                            // 幅を変えないよう常に置いておき，切り替え中だけ見せる（バーの幅＝窓の最小幅が揺れないように）
                            ProgressView().controlSize(.small)
                                .opacity(state.isSwitchingPersonMode ? 1 : 0)
                        }
                    }
                    Divider().frame(height: 44 * uiScale)
                    if state.playbackURL != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("再生映像").foregroundStyle(.secondary)
                            // 録画に無い種類は押せないようにする（横 1 列の並びは保つ）
                            ChoiceGrid(options: AppState.PlaybackVariant.allCases.map { v in
                                           (v, v.label, state.availableVariants.contains(v))
                                       },
                                       selection: $state.playbackVariant,
                                       columns: AppState.PlaybackVariant.allCases.count)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("表示").foregroundStyle(.secondary)
                            ChoiceGrid(options: [(LiveStyle.raw, "生映像", true), (.skeleton, "skeleton", true),
                                                 (.overlay, "overlay", true), (.hidden, "非表示", true)],
                                       selection: $state.liveStyle)
                        }
                        // 部位とミラー（1 行目: 顔・体・ミラー / 2 行目: 左手・右手）
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow {
                                if state.liveStyle.showsLandmarks {
                                    Toggle("顔", isOn: $state.drawOptions.face)
                                    Toggle("体（pose）", isOn: $state.drawOptions.pose)
                                }
                                Toggle("ミラー", isOn: $mirrorLive)
                                    .help("表示を左右反転する（鏡のように見せる）．録画や CSV の座標は変わらない")
                            }
                            if state.liveStyle.showsLandmarks {
                                GridRow {
                                    Toggle("左手", isOn: $state.drawOptions.leftHand)
                                    Toggle("右手", isOn: $state.drawOptions.rightHand)
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidths.left = $0 }

                HStack(spacing: 4) {
                    CameraControlButton(
                        icon: state.isRecording ? "stop.circle.fill" : "record.circle",
                        label: state.isRecording ? "Stop" : "Record",
                        tint: state.isRecording ? .red : (state.isReady ? .primary : .secondary),
                        minWidth: 88, large: true
                    ) { state.toggleRecording() }
                    .disabled(!state.isReady || state.isImporting)
                    .help(state.playbackURL != nil ? "録画を始めると再生は止まります" : "")
                    .keyboardShortcut("r", modifiers: .command)

                    CameraControlButton(
                        icon: state.playbackURL != nil ? "video.circle" : "play.circle",
                        label: state.playbackURL != nil ? "Live" : "Play",
                        tint: (state.lastOverlayURL != nil && !state.isRecording) ? .primary : .secondary,
                        minWidth: 88, large: true
                    ) { state.togglePlayback() }
                    .disabled(state.lastOverlayURL == nil || state.isRecording || state.isImporting)
                    .help("最新の録画を再生 / カメラ映像に戻る")
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidths.center = $0 }

                HStack(spacing: 0) {
                    CameraControlButton(
                        icon: "folder.badge.plus", label: "選んで再生…",
                        tint: state.isRecording ? .secondary : .primary
                    ) { state.openRecordingForPlayback() }
                    .disabled(state.isRecording || state.isImporting)
                    .help("過去の録画を選んで再生")

                    CameraControlButton(
                        icon: state.isImporting ? "xmark.circle" : "square.and.arrow.down",
                        label: state.isImporting ? "中止" : "動画を処理…",
                        tint: state.isImporting ? .red : ((state.isReady && !state.isRecording) ? .primary : .secondary)
                    ) { state.isImporting ? state.cancelImport() : state.importVideo() }
                    .disabled(!state.isReady || state.isRecording)
                    .help("動画ファイルを読み込んでランドマークを抽出し，CSV / JSON / 動画3種を生成して再生する")

                    CameraControlButton(icon: "folder", label: "Reveal", tint: .primary) { state.revealOutput() }

                    CameraControlButton(icon: "folder.badge.gearshape", label: "保存先…",
                                        tint: state.isRecording ? .secondary : .primary) { state.chooseOutputRoot() }
                    .disabled(state.isRecording)
                    .contextMenu {
                        Button("既定の保存先に戻す") { state.resetOutputRoot() }
                            .disabled(state.isDefaultOutputRoot || state.isRecording)
                    }
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidths.right = $0 }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, barPadding)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ZStack {
                if state.playbackURL != nil, state.playbackVariant == .hidden {
                    // 映像を出さずに波形だけ再生する
                    Text("映像は非表示（波形のみ再生中）").foregroundStyle(.secondary)
                } else if state.playbackURL == nil, state.liveStyle == .hidden {
                    Text("映像は非表示（推論と波形は動作中）").foregroundStyle(.secondary)
                } else if let tiles = state.tileSource {
                    // 複数人モード：全体映像＋人物ごとのタイル（ライブ・人物番号付きの録画の再生）
                    PeopleTileGrid(frame: tiles.frame, boxes: tiles.boxes, tiles: tiles.tiles,
                                   mirror: state.playbackURL == nil && mirrorLive)
                } else if state.playbackURL != nil {
                    // 録画の再生（カメラ映像と同じ領域に表示）
                    PlayerView(player: state.player)
                        .aspectRatio(state.playbackAspect, contentMode: .fit)
                        .background(Color(cgColor: SkeletonRenderer.sketchBackground))
                } else if let img = state.displayImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(CGFloat(img.width) / CGFloat(img.height), contentMode: .fit)
                        .scaleEffect(x: mirrorLive ? -1 : 1, y: 1)   // ミラー表示（表示だけ反転）
                        .background(Color(cgColor: SkeletonRenderer.sketchBackground))
                } else if state.camera.permissionDenied {
                    VStack(spacing: 12) {
                        Text("カメラへのアクセスが許可されていません")
                            .font(.title3.weight(.semibold))
                        Text("システム設定 > プライバシーとセキュリティ > カメラ で MotionLandmarker をオンにし，アプリを起動し直してください．\nオンなのに拒否される場合は，ターミナルで次を実行して許可を初期化してから起動し直します．")
                            .multilineTextAlignment(.center)
                        Text("tccutil reset Camera Theta-Akihisa.MotionLandmarker")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        Button("システム設定のカメラ項目を開く") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 映像エリアの大きさから人物タイルのマスの縦横比を求め，切り出しに使う（大きさが変わるたびに合わせ直す）
            // 仕切りのドラッグや窓の拡大縮小の最中は毎フレーム大きさが変わるので，変化が止まってから 1 回だけ合わせ直す
            // （その都度切り出しをやり直すと，ドラッグがカクつく）
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { state.tileAspects = PersonTiles.cellAspects(for: geo.size) }
                    .onChange(of: geo.size) { _, size in
                        tileAspectTask?.cancel()
                        tileAspectTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            state.tileAspects = PersonTiles.cellAspects(for: size)
                        }
                    }
            })
            .background(state.displayImage == nil || (state.playbackURL != nil && state.playbackVariant == .hidden)
                        || (state.playbackURL == nil && state.liveStyle == .hidden)
                        ? Color(cgColor: SkeletonRenderer.sketchBackground) : .clear)
            .overlay(alignment: .bottomLeading) {
                if !state.camera.currentCameraName.isEmpty {
                    Text(state.camera.currentCameraName)
                        .font(.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if let url = state.playbackURL {
                    Text(state.playbackHasWaveform
                         ? "再生中: \(url.lastPathComponent)"
                         : "再生中: \(url.lastPathComponent)（波形データなし）")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .center) {
                if state.isImporting {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(state.importProgress.done),
                                     total: Double(max(1, state.importProgress.total)))
                            .frame(width: 320)
                        Text("処理中: \(state.importName)  \(state.importProgress.done) / \(state.importProgress.total) フレーム")
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .overlay(alignment: .topTrailing) {
                if state.isRecording {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("REC \(state.recordedFrames)").font(.caption2.weight(.medium)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(12)
                }
            }
        }
    }

    private var sidecarStatus: some View {
        HStack(spacing: 6) {
            switch state.sidecarState {
            case .idle, .preparing:
                ProgressView().controlSize(.small)
                if case .preparing(let msg) = state.sidecarState { Text(msg) }
            case .ready:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(String(format: "MediaPipe %.1f fps", state.inferenceFPS)).monospacedDigit()
            case .failed(let msg):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(msg).lineLimit(2).help(msg)
                Button("ログ") { state.showSidecarLog() }
                Button("再起動") { state.restartSidecar() }
                    .disabled(state.isRecording || state.isImporting)
            }
        }
        .font(.callout)
    }

    // MARK: - 映像とグラフの間の行（推論の状態・保存先・カメラ選択・メッセージ）
    private var statusRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 16) {
                sidecarStatus
                Spacer()
                HStack(spacing: 6) {
                    Text("保存先:").foregroundStyle(.secondary)
                    Text(state.outputRoot.path).lineLimit(1).truncationMode(.middle)
                        .help(state.outputRoot.path)
                    if !state.isDefaultOutputRoot {
                        Button("既定に戻す") { state.resetOutputRoot() }
                            .buttonStyle(.link).disabled(state.isRecording)
                    }
                }
                .font(.callout)
                Spacer()
                @Bindable var camera = state.camera
                Picker("カメラ", selection: $camera.selectedDeviceID) {
                    ForEach(state.camera.devices, id: \.id) { d in
                        Text(d.name).tag(d.id)
                    }
                }
                .frame(maxWidth: 320)
                .disabled(state.camera.devices.isEmpty)
            }
            .padding(.horizontal, 12)
            if let msg = state.statusMessage {
                Text(msg).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 波形グラフ
    private var graphSection: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("表示モード", selection: $state.metricMode) {
                    ForEach(MetricMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .font(.title3)
                if !state.personChoices.isEmpty {
                    // 複数人モード：グラフに出す人物（映像の枠・タイルの番号と同じ）
                    Picker("人物", selection: $state.selectedPerson) {
                        ForEach(state.personChoices, id: \.self) { n in Text("\(n)人目").tag(n) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: CGFloat(state.personChoices.count) * 64 * uiScale)
                    .help("グラフに出す人物（映像の枠・タイルの番号と同じ）．その人が写っていないフレームは欠損")
                }
                Text(state.metricMode == .upperBody
                     ? "頭・体の向きと手首の位置・速度"
                     : "肘から手までの動き（前腕の角度・手の向き・手の開き・手首の速度）")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if state.playbackURL != nil {
                    if let r = zoomRange {
                        Text(String(format: "表示範囲 %.2f – %.2f 秒", r.lowerBound, r.upperBound))
                            .font(.callout).monospacedDigit()
                        Button("全体") { zoomRange = nil }
                    } else {
                        Text("ピンチ / ホイールで横軸をズーム，横スクロールで移動")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("グラフ項目").font(.title2.weight(.semibold)).padding(.bottom, 4)
                        ForEach(state.metricMode.charts) { chart in
                            Toggle(chart.title, isOn: chartBinding(chart)).font(.title3.weight(.semibold))
                            ForEach(chart.kinds) { k in
                                Toggle(k.label, isOn: metricBinding(k)).font(.title3).padding(.leading, 18)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(12)
                }
                .frame(width: checkboxColumnWidth)
                columnResizeHandle
                ScrollView {
                    // 再生中は録画全体（ズーム中はその範囲）を横軸に出し，赤い線がシークバーと同じ位置を動く。
                    // それ以外はライブの波形
                    // 人物番号付きの録画では選んだ人物の時系列（AppState.graphTimeline）
                    let timeline = state.playbackURL != nil ? state.graphTimeline : nil
                    let zoomed = (timeline != nil && zoomRange != nil)
                        ? timeline!.range(fromSeconds: visibleRange.lowerBound, toSeconds: visibleRange.upperBound) : nil
                    let times = zoomed?.times ?? (timeline != nil ? state.playbackAllTimes : state.history.times)
                    let endTime = timeline.map { $0.date(atVideoTime: state.playbackSeconds) }
                    let fullDomain: ClosedRange<Date>? = timeline.map { t in
                        zoomRange != nil
                            ? t.date(atVideoTime: visibleRange.lowerBound)...t.date(atVideoTime: visibleRange.upperBound)
                            : t.fullDomain(durationSeconds: state.playbackDuration)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(state.metricMode.charts) { chart in
                            let kinds = chart.kinds.filter { isVisible($0, in: chart) }
                            if !kinds.isEmpty {
                                MultiSeriesGraphView(
                                    title: chart.title,
                                    series: kinds.map { k in
                                        MultiSeriesGraphView.Series(
                                            id: k.rawValue, label: k.label,
                                            data: zoomed.map { $0.series[k] ?? [] }
                                                ?? timeline.map { $0.values[k] ?? [] } ?? state.history[k],
                                            color: color(for: k))
                                    },
                                    unit: chart.unit, range: chart.yRange, times: times,
                                    endTime: state.playbackURL != nil ? endTime : state.chartNow,
                                    fixedDomain: fullDomain,
                                    indexOffset: timeline != nil ? 0 : state.history.startIndex)
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { graphsFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in graphsFrame = f }
                })
                // トラックパッドのピンチでズーム（開始位置を中心に）
                .gesture(
                    MagnifyGesture()
                        .onChanged { g in
                            guard state.playbackURL != nil else { return }
                            if magnifyStartRange == nil { magnifyStartRange = visibleRange }
                            let start = magnifyStartRange ?? visibleRange
                            let anchor = seconds(atX: g.startLocation.x)
                            zoomRange = start
                            zoom(by: Double(g.magnification), anchor: anchor)
                        }
                        .onEnded { _ in magnifyStartRange = nil }
                )
                .onAppear { installScrollMonitor() }
                .onDisappear { removeScrollMonitor() }
                .onChange(of: state.playbackURL) { _, _ in zoomRange = nil }
                .onChange(of: state.playbackSeconds) { _, _ in followPlayback() }
            }
        }
    }

    private func isVisible(_ k: MetricKind, in chart: MetricChart) -> Bool {
        !state.hiddenCharts.contains(chart.id) && !state.hiddenMetrics.contains(k)
    }

    private func chartBinding(_ chart: MetricChart) -> Binding<Bool> {
        Binding(get: { !state.hiddenCharts.contains(chart.id) },
                set: { on in if on { state.hiddenCharts.remove(chart.id) } else { state.hiddenCharts.insert(chart.id) } })
    }

    private func metricBinding(_ k: MetricKind) -> Binding<Bool> {
        Binding(get: { !state.hiddenMetrics.contains(k) },
                set: { on in if on { state.hiddenMetrics.remove(k) } else { state.hiddenMetrics.insert(k) } })
    }

    /// 映像のランドマークと同じパレットから取る（Palette 参照）
    private func color(for k: MetricKind) -> Color {
        switch k {
        case .faceYaw: return Color(cgColor: Palette.face)
        case .facePitch: return Color(cgColor: Palette.faceAlt1)
        case .faceRoll: return Color(cgColor: Palette.faceAlt2)
        case .bodyYaw: return Color(cgColor: Palette.body)
        case .bodyRoll: return Color(cgColor: Palette.bodyAlt)
        default:
            if k.isLeft { return Color(cgColor: Palette.leftHand) }
            return Color(cgColor: Palette.rightHand)
        }
    }

}

// MARK: - Helper views

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title2.weight(.semibold)).padding(.horizontal)
    }
}

private struct CameraControlButton: View {
    let icon: String
    let label: String
    let tint: Color
    /// 最小幅（pt．文字の倍率を掛ける）。Record / Play は 88，右端のボタンは 64
    var minWidth: CGFloat = 64
    /// Record / Play 用の大きめの表示（アイコンと文字を大きくし，高さも増やす）
    var large = false
    let action: () -> Void
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: (large ? 26 : 18) * uiScale)).foregroundStyle(tint)
                Text(label).font(large ? .body.weight(.medium) : .callout).foregroundStyle(tint).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 4)
            .frame(minWidth: minWidth * uiScale, minHeight: (large ? 60 : 48) * uiScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 選択肢を `columns` 列のボタンの格子に並べる（セグメントは 1 行にしか並ばないため）。
/// `enabled` が false の選択肢は押せない（並びは保つ）
private struct ChoiceGrid<Value: Hashable>: View {
    let options: [(value: Value, label: String, enabled: Bool)]
    @Binding var selection: Value
    var columns = 2
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 2) {
            ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, options.count), id: \.self) { i in
                        let o = options[i]
                        Toggle(isOn: Binding(get: { selection == o.value },
                                             set: { if $0 { selection = o.value } })) {
                            Text(o.label).frame(minWidth: 52 * uiScale)   // ボタンの縁を含めて 64pt 程度
                        }
                        .toggleStyle(.button)
                        .disabled(!o.enabled)
                    }
                }
            }
        }
    }
}

private struct BarWidths: Equatable {
    var left: CGFloat = 0
    var center: CGFloat = 0
    var right: CGFloat = 0
}

/// 3 つの要素を左・中央・右に置く（表示設定バー用）。
/// 左右の領域を同じ幅（広い方の幅）とみなし，その間に中央の要素を置くので，中央の要素は常にバー全体の中央に来る。
/// 左の中身は左寄せ，右の中身は右寄せ。幅は毎回測り直すので，文字の倍率を変えても中央に揃う
private struct BarLayout: Layout {
    var spacing: CGFloat = 12

    private func sizes(_ subviews: Subviews) -> (side: CGFloat, center: CGSize, all: [CGSize]) {
        let all = subviews.map { $0.sizeThatFits(.unspecified) }
        guard all.count == 3 else { return (0, .zero, all) }
        return (max(all[0].width, all[2].width), all[1], all)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = sizes(subviews)
        let needed = 2 * s.side + s.center.width + 2 * spacing
        return CGSize(width: max(proposal.width ?? needed, needed), height: s.all.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = sizes(subviews)
        guard s.all.count == 3 else {
            for v in subviews { v.place(at: bounds.origin, proposal: .unspecified) }
            return
        }
        let left = s.all[0], right = s.all[2]
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - left.height / 2), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX - s.center.width / 2, y: bounds.midY - s.center.height / 2),
                          proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX - right.width, y: bounds.midY - right.height / 2),
                          proposal: .unspecified)
    }
}

/// 複数人モードの映像エリア：全体映像（各人の枠と番号を重ねる）＋人物ごとのタイル。
/// 人物タイルは見えている番号の最大値まで並べ，いない番号は空きの枠を残す（PersonTiles.personTileCount）。
/// 並べ方は PersonTiles.grid（4 タイル以下は横 1 列，5〜6 タイルは 2×3）。全体映像が左上，n 人目は n 番目
private struct PeopleTileGrid: View {
    let frame: CGImage
    let boxes: [PersonBox]
    let tiles: [Int: CGImage]
    /// ライブのミラー表示。映像と枠の位置だけ反転し，番号の文字は反転しない
    let mirror: Bool
    private let spacing = PersonTiles.tileSpacing

    var body: some View {
        let count = PersonTiles.personTileCount(boxes)
        let g = PersonTiles.grid(personCount: count)
        GeometryReader { geo in
            let cw = max(1, (geo.size.width - spacing * CGFloat(g.columns - 1)) / CGFloat(g.columns))
            let ch = max(1, (geo.size.height - spacing * CGFloat(g.rows - 1)) / CGFloat(g.rows))
            ZStack(alignment: .topLeading) {
                fullView
                    .frame(width: cw, height: ch)
                ForEach((0..<count).map { $0 + 1 }, id: \.self) { slot in
                    let c = PersonTiles.cell(index: slot, personCount: count)
                    personView(slot: slot, box: boxes.first { $0.slot == slot })
                        .frame(width: cw, height: ch)
                        .offset(x: CGFloat(c.column) * (cw + spacing), y: CGFloat(c.row) * (ch + spacing))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private static func color(_ slot: Int) -> Color { Color(cgColor: Palette.person(slot)) }

    private var fullView: some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .scaleEffect(x: mirror ? -1 : 1, y: 1)
            .aspectRatio(CGFloat(frame.width) / CGFloat(max(1, frame.height)), contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ForEach(boxes) { b in
                        let x = mirror ? 1 - b.bbox.maxX : b.bbox.minX
                        let r = CGRect(x: x * geo.size.width, y: b.bbox.minY * geo.size.height,
                                       width: b.bbox.width * geo.size.width, height: b.bbox.height * geo.size.height)
                        Rectangle()
                            .stroke(Self.color(b.slot), style: StrokeStyle(lineWidth: 2, dash: b.detected ? [] : [6, 4]))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                        badge("\(b.slot)", slot: b.slot)
                            .position(x: r.minX + 12, y: r.minY + 11)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(cgColor: SkeletonRenderer.sketchBackground))
    }

    /// n 人目のタイル。その番号の人がいなければ（box が nil）空きの枠に「未検出」と出す
    private func personView(slot: Int, box: PersonBox?) -> some View {
        ZStack(alignment: .topLeading) {
            Color(cgColor: SkeletonRenderer.sketchBackground)
            if box == nil {
                Text("未検出").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let img = tiles[slot] {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .scaleEffect(x: mirror ? -1 : 1, y: 1)
                    .aspectRatio(CGFloat(img.width) / CGFloat(max(1, img.height)), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            badge("\(slot)人目", slot: slot).padding(6)
        }
        .overlay(Rectangle().stroke(Self.color(slot), lineWidth: 2))
        .opacity(box?.detected ?? true ? 1 : 0.6)
    }

    private func badge(_ text: String, slot: Int) -> some View {
        Text(text)
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.color(slot), in: RoundedRectangle(cornerRadius: 4))
    }
}
