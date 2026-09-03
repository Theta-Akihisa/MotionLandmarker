//
//  LandmarkRecorder.swift
//  MotionLandmarker
//
//  録画 1 回分の出力。video2landmark（run.py）と同じ配置・同じ列構成で書く：
//    results_data/csv/{stem}/{stem}_{face,hand,pose}.csv
//    results_data/json/{stem}/{stem}_{face,hand,pose}.json
//    results_data/video_raw/{stem}_raw.mp4          （生映像）
//    results_data/video_overlay/{stem}_overlay.mp4  （映像＋ランドマーク）
//    results_data/video_skeleton/{stem}_skeleton.mp4（ランドマークのみ）
//  推論を通ったフレームだけを記録するため，動画のフレーム数と CSV / JSON の行数は通常一致する。
//

import AVFoundation
import CoreGraphics
import Foundation

nonisolated final class LandmarkRecorder {
    let stem: String
    let rawURL: URL
    let overlayURL: URL
    let skeletonURL: URL
    let csvDirectory: URL
    let jsonDirectory: URL

    private let size: CGSize
    private let raw: H264Writer
    private let overlay: H264Writer
    private let skeleton: H264Writer
    private let csv: LandmarkCSVWriter
    private var jsonFace: [[String: Any]] = []
    private var jsonHand: [[String: Any]] = []
    private var jsonPose: [[String: Any]] = []
    private(set) var frameCount = 0

    /// エンコーダが受け付けず動画に書けなかったフレーム数（CSV / JSON には残る）
    var skippedVideoFrames: Int { raw.skipped + overlay.skipped + skeleton.skipped }

    init(outputRoot: URL, stem: String, size: CGSize) throws {
        self.stem = stem
        self.size = size
        let fm = FileManager.default
        csvDirectory = outputRoot.appendingPathComponent("csv").appendingPathComponent(stem)
        jsonDirectory = outputRoot.appendingPathComponent("json").appendingPathComponent(stem)
        let rawDir = outputRoot.appendingPathComponent("video_raw")
        let overlayDir = outputRoot.appendingPathComponent("video_overlay")
        let skeletonDir = outputRoot.appendingPathComponent("video_skeleton")
        for d in [csvDirectory, jsonDirectory, rawDir, overlayDir, skeletonDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        rawURL = rawDir.appendingPathComponent("\(stem)_raw.mp4")
        overlayURL = overlayDir.appendingPathComponent("\(stem)_overlay.mp4")
        skeletonURL = skeletonDir.appendingPathComponent("\(stem)_skeleton.mp4")
        raw = try H264Writer(url: rawURL, size: size)
        overlay = try H264Writer(url: overlayURL, size: size)
        skeleton = try H264Writer(url: skeletonURL, size: size)
        csv = try LandmarkCSVWriter(directory: csvDirectory, stem: stem)
    }

    func append(_ frame: LandmarkFrame, background: CGImage?) {
        raw.append(timestampMs: frame.timestampMs) { ctx in
            SkeletonRenderer.compose(nil, background: background, in: ctx, size: size)
        }
        overlay.append(timestampMs: frame.timestampMs) { ctx in
            SkeletonRenderer.compose(frame, background: background, in: ctx, size: size)
        }
        skeleton.append(timestampMs: frame.timestampMs) { ctx in
            SkeletonRenderer.compose(frame, background: nil, in: ctx, size: size)
        }
        csv.append(frameIndex: frameCount, frame: frame)
        LandmarkJSON.append(frameIndex: frameCount, frame: frame,
                            face: &jsonFace, hand: &jsonHand, pose: &jsonPose)
        frameCount += 1
    }

    func finish(completion: @escaping @Sendable (Error?) -> Void) {
        csv.close()
        do {
            try LandmarkJSON.write(jsonFace, to: jsonDirectory.appendingPathComponent("\(stem)_face.json"))
            try LandmarkJSON.write(jsonHand, to: jsonDirectory.appendingPathComponent("\(stem)_hand.json"))
            try LandmarkJSON.write(jsonPose, to: jsonDirectory.appendingPathComponent("\(stem)_pose.json"))
        } catch {
            completion(error); return
        }
        let group = DispatchGroup()
        let box = ErrorBox()
        for w in [raw, overlay, skeleton] {
            group.enter()
            w.finish { e in
                if let e { box.set(e) }
                group.leave()
            }
        }
        // メインスレッドが待機している場合（終了処理）でも完了できるようグローバルキューへ
        group.notify(queue: .global()) { completion(box.get()) }
    }
}

nonisolated private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}

/// H.264 の mp4 を AVAssetWriter で書く。
nonisolated final class H264Writer: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var started = false
    private var lastTime: CMTime = .invalid
    private(set) var skipped = 0

    init(url: URL, size: CGSize) throws {
        self.url = url
        self.size = size
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw writer.error ?? NSError(domain: "MotionLandmarker", code: 1) }
        writer.add(input)
    }

    func append(timestampMs: Int, draw: (CGContext) -> Void) {
        let time = CMTime(value: CMTimeValue(timestampMs), timescale: 1000)
        if !started {
            guard writer.startWriting() else { skipped += 1; return }
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard lastTime == .invalid || time > lastTime else { skipped += 1; return }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { skipped += 1; return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { skipped += 1; return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                               width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
            draw(ctx)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if adaptor.append(pb, withPresentationTime: time) { lastTime = time } else { skipped += 1 }
    }

    func finish(completion: @escaping @Sendable (Error?) -> Void) {
        guard started else {
            writer.cancelWriting()
            completion(nil); return
        }
        input.markAsFinished()
        let writer = self.writer
        writer.finishWriting { completion(writer.error) }
    }
}

/// video2landmark の save2csv.py と同じ列構成。
nonisolated final class LandmarkCSVWriter {
    private let face: FileHandle
    private let hand: FileHandle
    private let pose: FileHandle

    static var faceHeader: String {
        var h = ["frame", "timestamp_ms"]
        for i in 0..<LandmarkFrame.faceCount { h += ["lm_\(i)_x", "lm_\(i)_y", "lm_\(i)_z"] }
        return h.joined(separator: ",")
    }
    static var handHeader: String {
        var h = ["frame", "timestamp_ms"]
        for side in ["left", "right"] {
            for i in 0..<LandmarkFrame.handCount { h += ["\(side)_\(i)_x", "\(side)_\(i)_y", "\(side)_\(i)_z"] }
        }
        return h.joined(separator: ",")
    }
    static var poseHeader: String {
        var h = ["frame", "timestamp_ms"]
        for i in 0..<LandmarkFrame.poseCount { h += ["lm_\(i)_x", "lm_\(i)_y", "lm_\(i)_z", "lm_\(i)_visibility"] }
        return h.joined(separator: ",")
    }

    static func faceRow(frameIndex: Int, frame: LandmarkFrame) -> String {
        (["\(frameIndex)", "\(frame.timestampMs)"] + xyz(frame.face, count: LandmarkFrame.faceCount))
            .joined(separator: ",")
    }
    static func handRow(frameIndex: Int, frame: LandmarkFrame) -> String {
        (["\(frameIndex)", "\(frame.timestampMs)"]
         + xyz(frame.leftHand, count: LandmarkFrame.handCount)
         + xyz(frame.rightHand, count: LandmarkFrame.handCount)).joined(separator: ",")
    }
    static func poseRow(frameIndex: Int, frame: LandmarkFrame) -> String {
        var cols = ["\(frameIndex)", "\(frame.timestampMs)"]
        if frame.pose.count == LandmarkFrame.poseCount {
            for lm in frame.pose { cols += ["\(lm.x)", "\(lm.y)", "\(lm.z)", "\(lm.visibility)"] }
        } else {
            cols += Array(repeating: "", count: LandmarkFrame.poseCount * 4)
        }
        return cols.joined(separator: ",")
    }

    private static func xyz(_ lms: [Landmark], count: Int) -> [String] {
        guard lms.count == count else { return Array(repeating: "", count: count * 3) }
        var out: [String] = []
        out.reserveCapacity(count * 3)
        for lm in lms { out += ["\(lm.x)", "\(lm.y)", "\(lm.z)"] }
        return out
    }

    init(directory: URL, stem: String) throws {
        func open(_ name: String, header: String) throws -> FileHandle {
            let url = directory.appendingPathComponent(name)
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
            let fh = try FileHandle(forWritingTo: url)
            try fh.seekToEnd()
            return fh
        }
        face = try open("\(stem)_face.csv", header: Self.faceHeader)
        hand = try open("\(stem)_hand.csv", header: Self.handHeader)
        pose = try open("\(stem)_pose.csv", header: Self.poseHeader)
    }

    func append(frameIndex: Int, frame: LandmarkFrame) {
        face.write(Data((Self.faceRow(frameIndex: frameIndex, frame: frame) + "\n").utf8))
        hand.write(Data((Self.handRow(frameIndex: frameIndex, frame: frame) + "\n").utf8))
        pose.write(Data((Self.poseRow(frameIndex: frameIndex, frame: frame) + "\n").utf8))
    }

    func close() {
        for fh in [face, hand, pose] { try? fh.close() }
    }
}

/// video2landmark の save2json.py と同じ構造（未検出は null，hand は left / right キー）。
nonisolated enum LandmarkJSON {
    static func append(frameIndex: Int, frame: LandmarkFrame,
                       face: inout [[String: Any]], hand: inout [[String: Any]], pose: inout [[String: Any]]) {
        func xyz(_ lms: [Landmark], count: Int) -> Any {
            guard lms.count == count else { return NSNull() }
            return lms.map { ["x": $0.x, "y": $0.y, "z": $0.z] }
        }
        face.append(["frame": frameIndex, "timestamp_ms": frame.timestampMs,
                     "landmarks": xyz(frame.face, count: LandmarkFrame.faceCount)])
        hand.append(["frame": frameIndex, "timestamp_ms": frame.timestampMs,
                     "left": xyz(frame.leftHand, count: LandmarkFrame.handCount),
                     "right": xyz(frame.rightHand, count: LandmarkFrame.handCount)])
        let p: Any = frame.pose.count == LandmarkFrame.poseCount
            ? frame.pose.map { ["x": $0.x, "y": $0.y, "z": $0.z, "visibility": $0.visibility] }
            : NSNull()
        pose.append(["frame": frameIndex, "timestamp_ms": frame.timestampMs, "landmarks": p])
    }

    static func write(_ rows: [[String: Any]], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
