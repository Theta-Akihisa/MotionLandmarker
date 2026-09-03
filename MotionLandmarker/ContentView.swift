//
//  ContentView.swift
//  MotionLandmarker
//

import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

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
                if let img = state.displayImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(CGFloat(img.width) / CGFloat(img.height), contentMode: .fit)
                        .background(Color(cgColor: SkeletonRenderer.sketchBackground))
                } else if state.camera.permissionDenied {
                    Text("カメラへのアクセスが許可されていません（システム設定 > プライバシーとセキュリティ > カメラ）")
                        .foregroundStyle(.white).padding()
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
                .keyboardShortcut("r", modifiers: .command)

                CameraControlButton(
                    icon: "camera.rotate", label: "Switch",
                    tint: state.camera.canSwitchCamera ? .primary : .secondary
                ) { state.camera.switchCamera() }
                .disabled(!state.camera.canSwitchCamera)

                CameraControlButton(
                    icon: "play.circle", label: "Play",
                    tint: state.lastOverlayURL != nil ? .primary : .secondary
                ) { if let url = state.lastOverlayURL { openWindow(id: "videoPlayback", value: url) } }
                .disabled(state.lastOverlayURL == nil)

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
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("グラフ項目").font(.title2.weight(.semibold)).padding(.bottom, 4)
                    ForEach(MetricGroup.allCases) { g in
                        Toggle(g.label, isOn: groupBinding(g)).font(.title3.weight(.semibold))
                        ForEach(g.kinds) { k in
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
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(MetricChart.all) { chart in
                        let kinds = chart.kinds.filter { isVisible($0) }
                        if !kinds.isEmpty {
                            MultiSeriesGraphView(
                                title: chart.title,
                                series: kinds.map { k in
                                    MultiSeriesGraphView.Series(id: k.rawValue, label: k.label,
                                                                data: state.history[k], color: color(for: k))
                                },
                                unit: chart.unit, range: chart.yRange, times: state.history.times)
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func isVisible(_ k: MetricKind) -> Bool {
        state.visibleGroups.contains(k.group) && state.visibleMetrics.contains(k)
    }

    /// 映像のランドマークと同じパレットから取る（Palette 参照）
    private func color(for k: MetricKind) -> Color {
        switch k {
        case .faceYaw: return Color(cgColor: Palette.face)
        case .facePitch: return Color(cgColor: Palette.faceAlt1)
        case .faceRoll: return Color(cgColor: Palette.faceAlt2)
        case .bodyYaw: return Color(cgColor: Palette.body)
        case .bodyRoll: return Color(cgColor: Palette.bodyAlt)
        case .leftWristX, .leftWristY, .leftWristSpeed: return Color(cgColor: Palette.leftHand)
        case .rightWristX, .rightWristY, .rightWristSpeed: return Color(cgColor: Palette.rightHand)
        }
    }

    private func groupBinding(_ g: MetricGroup) -> Binding<Bool> {
        Binding(get: { state.visibleGroups.contains(g) },
                set: { on in if on { state.visibleGroups.insert(g) } else { state.visibleGroups.remove(g) } })
    }

    private func metricBinding(_ k: MetricKind) -> Binding<Bool> {
        Binding(get: { state.visibleMetrics.contains(k) },
                set: { on in if on { state.visibleMetrics.insert(k) } else { state.visibleMetrics.remove(k) } })
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
