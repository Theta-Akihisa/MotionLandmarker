//
//  ContentView.swift
//  MotionLandmarker
//

import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    /// 映像部分の高さ。仕切りをドラッグして変え，次回起動時も保持する。
    /// ドラッグ中は `draggingHeight` だけを動かし（UserDefaults への書き込みを避ける），終了時に保存する。
    @AppStorage("videoHeight") private var savedVideoHeight: Double = 360
    @State private var draggingHeight: Double?
    @State private var dragStartHeight: Double?
    private let videoHeightRange: ClosedRange<Double> = 160...1080
    /// グラフのプロット領域の中央 x（グラフ内のローカル座標）。現在位置の縦線に使う
    @State private var plotCenterX: CGFloat = 0
    private var videoHeight: Double { draggingHeight ?? savedVideoHeight }

    var body: some View {
        VStack(spacing: 0) {
            cameraSection
                .frame(height: videoHeight)
            controlButtons
            resizeHandle
            graphSection
                .frame(minHeight: 200)
        }
        .frame(minWidth: 900, minHeight: 600)
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
            DragGesture(minimumDistance: 1)
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
            HStack(spacing: 16) {
                Text("表示").foregroundStyle(.secondary)
                Toggle("顔", isOn: $state.drawOptions.face)
                Toggle("体（pose）", isOn: $state.drawOptions.pose)
                Toggle("左手", isOn: $state.drawOptions.leftHand)
                Toggle("右手", isOn: $state.drawOptions.rightHand)
                Spacer()
                sidecarStatus
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
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ZStack {
                if let url = state.playbackURL {
                    // 録画の再生（カメラ映像と同じ領域に表示）
                    PlayerView(player: state.player)
                        .aspectRatio(state.playbackAspect, contentMode: .fit)
                        .background(Color(cgColor: SkeletonRenderer.sketchBackground))
                } else if let img = state.displayImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(CGFloat(img.width) / CGFloat(img.height), contentMode: .fit)
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
            .background(state.displayImage == nil ? Color(cgColor: SkeletonRenderer.sketchBackground) : .clear)
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

    // MARK: - ボタン列
    private var controlButtons: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                CameraControlButton(
                    icon: state.isRecording ? "stop.circle.fill" : "record.circle",
                    label: state.isRecording ? "Stop" : "Record",
                    tint: state.isRecording ? .red : (state.isReady ? .primary : .secondary)
                ) { state.toggleRecording() }
                .disabled(!state.isReady || state.isImporting)
                .help(state.playbackURL != nil ? "録画を始めると再生は止まります" : "")
                .keyboardShortcut("r", modifiers: .command)

                CameraControlButton(
                    icon: "camera.rotate", label: "Switch",
                    tint: state.camera.canSwitchCamera ? .primary : .secondary
                ) { state.camera.switchCamera() }
                .disabled(!state.camera.canSwitchCamera)

                CameraControlButton(
                    icon: state.playbackURL != nil ? "video.circle" : "play.circle",
                    label: state.playbackURL != nil ? "Live" : "Play",
                    tint: (state.lastOverlayURL != nil && !state.isRecording) ? .primary : .secondary
                ) { state.togglePlayback() }
                .disabled(state.lastOverlayURL == nil || state.isRecording || state.isImporting)
                .help("最新の録画を再生 / カメラ映像に戻る")

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
            if let msg = state.statusMessage {
                Text(msg).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 10)
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
                Text(state.metricMode == .upperBody
                     ? "頭・体の向きと手首の位置・速度"
                     : "肘から手までの動き（前腕の角度・手の向き・手の開き・手首の速度）")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
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
                .frame(width: 270)
                Divider()
                ScrollView {
                    // 再生中は動画の再生位置に合わせて録画の波形を出す。それ以外はライブの波形
                    let playback = state.playbackURL != nil
                        ? state.playbackTimeline?.slice(atVideoTime: state.playbackSeconds, window: 10) : nil
                    let times = playback?.times ?? state.history.times
                    let endTime = state.playbackTimeline.map { $0.date(atVideoTime: state.playbackSeconds) }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.metricMode.charts) { chart in
                            let kinds = chart.kinds.filter { isVisible($0, in: chart) }
                            if !kinds.isEmpty {
                                MultiSeriesGraphView(
                                    title: chart.title,
                                    series: kinds.map { k in
                                        MultiSeriesGraphView.Series(
                                            id: k.rawValue, label: k.label,
                                            data: playback.map { $0.series[k] ?? [] } ?? state.history[k],
                                            color: color(for: k))
                                    },
                                    unit: chart.unit, range: chart.yRange, times: times,
                                    endTime: state.playbackURL != nil ? endTime : nil)
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .onPreferenceChange(PlotCenterXKey.self) { plotCenterX = $0 }
                    // 現在位置（再生中は再生位置）を示す縦線。横軸は現在位置が中央になるよう取っているので，
                    // 全グラフを縦に貫く 1 本の線をプロット領域の中央に重ねる
                    .overlay(alignment: .topLeading) {
                        if plotCenterX > 0 {
                            VStack(spacing: 0) {
                                Text(state.playbackURL != nil ? "再生位置" : "現在")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.red, in: Capsule())
                                Rectangle().fill(Color.red).frame(width: 2)
                            }
                            .padding(.vertical, 4)
                            // グラフ内ローカル座標 → この VStack の座標：外側の余白 16 + カード内の余白 12
                            .alignmentGuide(.leading) { d in d[HorizontalAlignment.center] - (16 + 12 + plotCenterX) }
                            .allowsHitTesting(false)
                        }
                    }
                }
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(tint)
                Text(label).font(.title3).foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
