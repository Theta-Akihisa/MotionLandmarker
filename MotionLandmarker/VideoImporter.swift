//
//  VideoImporter.swift
//  MotionLandmarker
//
//  動画ファイルを読み込み，カメラと同じパイプラインで全フレームを推論・描画・書き出しする。
//  出力は録画と同じ配置（csv / json / video_raw / video_overlay / video_skeleton），stem は動画のファイル名。
//

import AVFoundation
import Foundation

nonisolated enum VideoImporter {
    struct Result: Sendable {
        let stem: String
        let frames: Int
        let overlayURL: URL
        let skippedVideoFrames: Int
    }

    enum ImportError: LocalizedError {
        case cannotOpen, noFrames, timeout(Int), recorder(Error)
        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "動画を開けません"
            case .noFrames: return "動画からフレームを読み出せません"
            case .timeout(let n): return "推論が応答しません（フレーム \(n)）"
            case .recorder(let e): return "書き出しを開始できません: \(e.localizedDescription)"
            }
        }
    }

    /// バックグラウンドスレッドで呼ぶこと。`progress` は (処理済み, 総フレーム数の見込み)。
    static func run(videoURL: URL, outputRoot: URL, pipeline: LandmarkPipeline,
                    progress: @escaping @Sendable (Int, Int) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) throws -> Result {
        let asset = AVURLAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { throw ImportError.cannotOpen }
        let total = Int((asset.duration.seconds * Double(track.nominalFrameRate)).rounded())
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()

        let stem = videoURL.deletingPathExtension().lastPathComponent
        let done = DispatchSemaphore(value: 0)
        pipeline.onProcessed = { done.signal() }
        defer { pipeline.onProcessed = nil }

        var sent = 0
        var recorderStarted = false
        while let sb = output.copyNextSampleBuffer() {
            if isCancelled() { break }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let ms = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1000).rounded())
            pipeline.waitUntilIdle()
            guard pipeline.handleFileFrame(pb, ms) else { continue }
            sent += 1
            guard done.wait(timeout: .now() + 30) == .success else { throw ImportError.timeout(sent) }
            if !recorderStarted {
                // 録画サイズは最初のフレームから決まる（カメラと同じ流れ）。先頭フレームは記録に含めない
                do { try pipeline.startRecording(outputRoot: outputRoot, stem: stem) } catch {
                    throw ImportError.recorder(error)
                }
                recorderStarted = true
            }
            progress(sent, max(total, sent))
        }
        guard sent > 0 else { throw ImportError.noFrames }

        let finished = DispatchSemaphore(value: 0)
        let box = ResultBox()
        pipeline.stopRecording { r, e in box.set(r, e); finished.signal() }
        finished.wait()
        let (recorder, error) = box.get()
        if let error { throw error }
        guard let recorder else { throw ImportError.noFrames }
        return Result(stem: stem, frames: recorder.frameCount, overlayURL: recorder.overlayURL,
                      skippedVideoFrames: recorder.skippedVideoFrames)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (LandmarkRecorder?, Error?) = (nil, nil)
        func set(_ r: LandmarkRecorder?, _ e: Error?) { lock.lock(); value = (r, e); lock.unlock() }
        func get() -> (LandmarkRecorder?, Error?) { lock.lock(); defer { lock.unlock() }; return value }
    }
}
