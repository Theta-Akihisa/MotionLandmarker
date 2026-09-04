//
//  ContentView.swift
//  MotionLandmarker
//

import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    /// 映像部分の高さ。仕切りをドラッグして変え，次回起動時も保持する。
    @AppStorage("videoHeight") private var videoHeight: Double = 360
    @State private var dragStartHeight: Double?
    private let videoHeightRange: ClosedRange<Double> = 160...1080

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
                    if dragStartHeight == nil { dragStartHeight = videoHeight }
                    let h = (dragStartHeight ?? videoHeight) + g.translation.height
                    videoHeight = min(max(h, videoHeightRange.lowerBound), videoHeightRange.upperBound)
                }
                .onEnded { _ in dragStartHeight = nil }
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
                        .aspectRatio(CGFloat(state.displayImage?.width ?? 16) / CGFloat(state.displayImage?.height ?? 9),
                                     contentMode: .fit)
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
                .disabled(!state.isReady)
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
                .disabled(state.lastOverlayURL == nil || state.isRecording)
                .help("最新の録画を再生 / カメラ映像に戻る")

                CameraControlButton(
                    icon: "folder.badge.plus", label: "選んで再生…",
                    tint: state.isRecording ? .secondary : .primary
                ) { state.openRecordingForPlayback() }
                .disabled(state.isRecording)
                .help("過去の録画を選んで再生")

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
            .font(.caption)
            if let msg = state.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
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
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint)
                Text(label).font(.caption).foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
