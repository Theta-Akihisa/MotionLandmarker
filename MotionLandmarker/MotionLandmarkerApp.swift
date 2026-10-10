//
//  MotionLandmarkerApp.swift
//  MotionLandmarker
//

import SwiftUI
import AVKit

@main
struct MotionLandmarkerApp: App {
    @State private var state = AppState()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// 画面の拡大段階（⌘+ / ⌘- / ⌘0）。次回起動時も保持する
    @AppStorage(UIScale.key) private var uiScaleStep: Int = 0

    init() {
        // `--check <動画>` は GUI を起動せずにパイプラインを検証して終了する
        if CommandLine.arguments.contains("--check") {
            exit(SelfCheck.run(arguments: CommandLine.arguments))
        }
        if CommandLine.arguments.contains("--import") {
            exit(SelfCheck.runImport(arguments: CommandLine.arguments))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .environment(\.dynamicTypeSize, UIScale.typeSize(for: uiScaleStep))
                .environment(\.uiScale, UIScale.factor(for: uiScaleStep))
                .onAppear {
                    delegate.state = state
                    state.start()
                }
        }
        .defaultSize(width: 1280, height: 1000)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("拡大") { uiScaleStep = UIScale.clamp(uiScaleStep + 1) }
                    .keyboardShortcut("=", modifiers: .command)       // ⌘+（Shift なし）
                Button("拡大 ") { uiScaleStep = UIScale.clamp(uiScaleStep + 1) }
                    .keyboardShortcut("+", modifiers: [.command, .shift])
                Button("縮小") { uiScaleStep = UIScale.clamp(uiScaleStep - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("実際のサイズ") { uiScaleStep = 0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// 録画した動画を映像エリアで再生するビュー。
/// AVKit の SwiftUI 版 `VideoPlayer` はこの環境で型メタデータの初期化に失敗して abort するため，
/// AppKit の AVPlayerView を直接使う。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none   // 操作はアプリ側の再生バーで行う
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 録画中に終了した場合，mp4 の末尾が書かれる前にプロセスが落ちないよう書き出し完了を待つ。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        if state.isRecording {
            state.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        state.shutdown {}
        return .terminateNow
    }
}
