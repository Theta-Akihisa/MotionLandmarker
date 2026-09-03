//
//  SelfCheck.swift
//  MotionLandmarker
//
//  `MotionLandmarker --check <動画> [サイドカーdir] [出力先]`
//  カメラの代わりに動画ファイルのフレームをアプリ本体と同じ LandmarkPipeline に流し，
//  CSV / JSON / raw / overlay / skeleton を書き出す。GUI もカメラも使わずにパイプライン全体を検証する。
//  サイドカーは指定ディレクトリ（既定は実行ファイルからみた ../../../../landmarker）を uv run で直接使う。
//

import AVFoundation
import Foundation

nonisolated enum SelfCheck {
    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--check"), i + 1 < arguments.count else { return 2 }
        let videoPath = arguments[i + 1]
        let sidecar = URL(fileURLWithPath: i + 2 < arguments.count ? arguments[i + 2]
                          : FileManager.default.currentDirectoryPath + "/landmarker")
        let outputRoot = URL(fileURLWithPath: i + 3 < arguments.count ? arguments[i + 3]
                             : FileManager.default.temporaryDirectory.appendingPathComponent("MotionLandmarker_check").path)
        guard let uv = SidecarBootstrap.locateUV() else { print("uv not found"); return 1 }

        let client = LandmarkerClient()
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        client.onReady = { ready.signal() }
        client.onExit = { code, log in if code != 0 { print("sidecar exited \(code)\n\(log)") } }
        let pipeline = LandmarkPipeline(client: client)
        let stats = Stats()
        pipeline.onFrame = { _, frame, _, recorded in
            stats.add(frame, recorded: recorded)
            done.signal()
        }
        do { try client.start(uv: uv, project: sidecar) } catch { print("sidecar start failed: \(error)"); return 1 }
        guard ready.wait(timeout: .now() + 120) == .success else { print("sidecar did not become ready"); return 1 }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { print("cannot open video: \(videoPath)"); return 1 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()

        let stem = "check_" + URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        var sent = 0
        let start = Date()
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let ms = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1000).rounded())
            pipeline.waitUntilIdle()
            pipeline.handleCameraFrame(pb, ms)
            sent += 1
            guard done.wait(timeout: .now() + 30) == .success else { print("timeout at frame \(sent)"); return 1 }
            if sent == 1 {
                // 録画サイズは最初のフレームから決まる（カメラと同じ流れ）
                do { try pipeline.startRecording(outputRoot: outputRoot, stem: stem) } catch {
                    print("recorder failed: \(error)"); return 1
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        let finished = DispatchSemaphore(value: 0)
        let result = ResultBox()
        pipeline.stopRecording { r, e in result.set(r, e); finished.signal() }
        finished.wait()
        client.stop()

        let (recorder, error) = result.get()
        let s = stats.snapshot()
        print("frames sent=\(sent) received=\(s.received) recorded=\(s.recorded) skipped_video=\(recorder?.skippedVideoFrames ?? 0) fps=\(String(format: "%.1f", Double(sent) / elapsed))")
        print("detected face=\(s.face) left=\(s.left) right=\(s.right) pose=\(s.pose)")
        if let error { print("finish error: \(error)"); return 1 }
        if let r = recorder {
            for u in [r.csvDirectory, r.jsonDirectory, r.rawURL, r.overlayURL, r.skeletonURL] { print("output: \(u.path)") }
        }
        return sent == s.received && sent > 0 ? 0 : 1
    }

    private final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var received = 0, recorded = 0, face = 0, left = 0, right = 0, pose = 0
        func add(_ f: LandmarkFrame, recorded r: Int) {
            lock.lock(); defer { lock.unlock() }
            received += 1; recorded = r
            if f.face.count == LandmarkFrame.faceCount { face += 1 }
            if f.leftHand.count == LandmarkFrame.handCount { left += 1 }
            if f.rightHand.count == LandmarkFrame.handCount { right += 1 }
            if f.pose.count == LandmarkFrame.poseCount { pose += 1 }
        }
        func snapshot() -> (received: Int, recorded: Int, face: Int, left: Int, right: Int, pose: Int) {
            lock.lock(); defer { lock.unlock() }
            return (received, recorded, face, left, right, pose)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (LandmarkRecorder?, Error?) = (nil, nil)
        func set(_ r: LandmarkRecorder?, _ e: Error?) { lock.lock(); value = (r, e); lock.unlock() }
        func get() -> (LandmarkRecorder?, Error?) { lock.lock(); defer { lock.unlock() }; return value }
    }
}
