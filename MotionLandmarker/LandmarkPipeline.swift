//
//  LandmarkPipeline.swift
//  MotionLandmarker
//
//  カメラフレーム → JPEG → サイドカー推論 → 描画 / 指標 / 録画 の流れ。メインアクタの外で動く。
//  状態はすべて `queue` 上で触る。
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class LandmarkPipeline: @unchecked Sendable {
    /// サイドカーに送る画像の幅（高さはアスペクト比から）。ランドマークは正規化座標なので表示解像度に影響しない。
    static let inferenceWidth = 640

    /// 1 フレームの処理結果：(描画済み画像, フレーム, 指標, 録画済みフレーム数)
    var onFrame: (@Sendable (CGImage?, LandmarkFrame, [MetricKind: Double], Int) -> Void)?

    private let queue = DispatchQueue(label: "landmark.pipeline")
    private let client: LandmarkerClient
    private var recorder: LandmarkRecorder?
    private var pending: [Int: CGImage] = [:]
    private var previousFrame: LandmarkFrame?
    private var frameSize = CGSize(width: 1280, height: 720)
    private var drawOptions = DrawOptions()

    init(client: LandmarkerClient) {
        self.client = client
        client.onResult = { [weak self] frame in self?.handleResult(frame) }
    }

    func setDrawOptions(_ o: DrawOptions) { queue.async { self.drawOptions = o } }

    var currentFrameSize: CGSize { queue.sync { frameSize } }
    var isRecording: Bool { queue.sync { recorder != nil } }

    /// カメラのスレッドから呼ばれる。推論中なら何もしない（フレームを捨てる）。
    func handleCameraFrame(_ pb: CVPixelBuffer, _ ms: Int) {
        guard client.isReady, !client.isBusy,
              let image = FrameEncoder.cgImage(from: pb),
              let jpeg = FrameEncoder.jpeg(image, width: Self.inferenceWidth) else { return }
        queue.sync {
            pending[ms] = image
            if pending.count > 4 {
                for k in pending.keys.sorted().dropLast(4) { pending[k] = nil }
            }
        }
        client.send(jpeg: jpeg, timestampMs: ms)
    }

    private func handleResult(_ frame: LandmarkFrame) {
        queue.async { [self] in
            // サイドカーは非単調なタイムスタンプを +1 に補正することがある。その場合は最新の画像を使う。
            let background = pending.removeValue(forKey: frame.timestampMs)
                ?? pending.keys.max().flatMap { pending.removeValue(forKey: $0) }
            let size = background.map { CGSize(width: $0.width, height: $0.height) } ?? frameSize
            frameSize = size
            let image = SkeletonRenderer.image(frame, background: background, size: size, options: drawOptions)
            recorder?.append(frame, background: background)
            let metrics = MotionMetrics.compute(frame, previous: previousFrame)
            previousFrame = frame
            onFrame?(image, frame, metrics, recorder?.frameCount ?? 0)
        }
    }

    func startRecording(outputRoot: URL, stem: String) throws {
        try queue.sync {
            recorder = try LandmarkRecorder(outputRoot: outputRoot, stem: stem, size: frameSize)
        }
    }

    /// 録画を閉じる。completion は (recorder, error)。録画していなければ recorder は nil。
    func stopRecording(completion: @escaping @Sendable (LandmarkRecorder?, Error?) -> Void) {
        queue.async { [self] in
            guard let r = recorder else { completion(nil, nil); return }
            recorder = nil
            r.finish { error in completion(r, error) }
        }
    }

    /// サイドカーが空くまで待つ（ファイル入力の検証用）
    func waitUntilIdle() {
        while client.isReady && client.isBusy { usleep(1000) }
    }
}

nonisolated enum FrameEncoder {
    /// CVPixelBuffer（32BGRA）→ CGImage。
    /// 画素は必ずコピーする。カメラはバッファをプールで再利用するため，バッファのメモリを
    /// 参照したままの CGImage を推論待ちの間（数十 ms）保持すると次のフレームで上書きされる。
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let copy = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 幅 `width` に縮小して JPEG にする
    static func jpeg(_ image: CGImage, width: Int, quality: Double = 0.85) -> Data? {
        let height = max(1, image.height * width / max(1, image.width))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
