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

    init() {
        // `--check <動画>` は GUI を起動せずにパイプラインを検証して終了する
        if CommandLine.arguments.contains("--check") {
            exit(SelfCheck.run(arguments: CommandLine.arguments))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .onAppear {
                    delegate.state = state
                    state.start()
                }
        }
        .defaultSize(width: 1280, height: 1000)

        // 録画した overlay 動画の再生ウィンドウ
        WindowGroup("Video Playback", id: "videoPlayback", for: URL.self) { $url in
            if let url = url {
                PlayerView(url: url)
                    .ignoresSafeArea()
                    .frame(minWidth: 640, minHeight: 360)
            }
        }
        .defaultSize(width: 1280, height: 720)
    }
}

/// AVKit の SwiftUI 版 `VideoPlayer` はこの環境で型メタデータの初期化に失敗して abort するため，
/// AppKit の AVPlayerView を直接使う。
struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
            view.player?.play()
        }
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
