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

    /// 1 フレームの処理が終わるたびに呼ばれる（onFrame の後）。ファイル処理の同期用
    var onProcessed: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "landmark.pipeline")
    private let client: LandmarkerClient
    private var recorder: LandmarkRecorder?
    /// サイドカーへ送った時刻（単調増加）→ (元画像, 元のタイムスタンプ)
    private var pending: [Int: (image: CGImage, originalMs: Int)] = [:]
    private var previousFrame: LandmarkFrame?
    private var frameSize = CGSize(width: 1280, height: 720)
    private var drawOptions = DrawOptions()
    /// サイドカーは単調増加のタイムスタンプを要求する。カメラと動画ファイルで時刻の基準が違うため，
    /// 送信時刻には必要に応じてオフセットを足し，結果を受け取るときに元の時刻へ戻す。
    private var wireOffset = 0
    private var lastWire = -1
    /// true のあいだカメラのフレームを捨てる（動画ファイルの処理中）
    private var cameraPaused = false

    init(client: LandmarkerClient) {
        self.client = client
        client.onResult = { [weak self] frame in self?.handleResult(frame) }
    }

    func setDrawOptions(_ o: DrawOptions) { queue.async { self.drawOptions = o } }

    var currentFrameSize: CGSize { queue.sync { frameSize } }
    var isRecording: Bool { queue.sync { recorder != nil } }

    /// カメラのフレームを捨てるかどうか（動画ファイルの処理中に true にする）
    func setCameraPaused(_ paused: Bool) {
        queue.sync {
            cameraPaused = paused
            previousFrame = nil   // 入力源が変わるので速度の基準をリセット
        }
    }

    /// カメラのスレッドから呼ばれる。推論中なら何もしない（フレームを捨てる）。
    func handleCameraFrame(_ pb: CVPixelBuffer, _ ms: Int) {
        guard !queue.sync(execute: { cameraPaused }) else { return }
        submit(pb, originalMs: ms)
    }

    /// 動画ファイルのフレームを送る（呼び出し側で 1 フレームずつ完了を待つこと）
    func handleFileFrame(_ pb: CVPixelBuffer, _ ms: Int) -> Bool {
        submit(pb, originalMs: ms)
    }

    @discardableResult
    private func submit(_ pb: CVPixelBuffer, originalMs: Int) -> Bool {
        guard client.isReady, !client.isBusy,
              let image = FrameEncoder.cgImage(from: pb),
              let jpeg = FrameEncoder.jpeg(image, width: Self.inferenceWidth) else { return false }
        let wire: Int = queue.sync {
            var w = originalMs + wireOffset
            if w <= lastWire {
                wireOffset = lastWire + 1 - originalMs
                w = originalMs + wireOffset
            }
            lastWire = w
            pending[w] = (image, originalMs)
            if pending.count > 4 {
                for k in pending.keys.sorted().dropLast(4) { pending[k] = nil }
            }
            return w
        }
        return client.send(jpeg: jpeg, timestampMs: wire)
    }

    private func handleResult(_ result: LandmarkFrame) {
        queue.async { [self] in
            // 送信時刻で元画像と元のタイムスタンプを引く。見つからなければ最新のものを使う
            let entry = pending.removeValue(forKey: result.timestampMs)
                ?? pending.keys.max().flatMap { pending.removeValue(forKey: $0) }
            var frame = result
            if let entry { frame.timestampMs = entry.originalMs }
            let background = entry?.image
            let size = background.map { CGSize(width: $0.width, height: $0.height) } ?? frameSize
            frameSize = size
            let image = SkeletonRenderer.image(frame, background: background, size: size, options: drawOptions)
            let metrics = MotionMetrics.compute(frame, previous: previousFrame)
            previousFrame = frame
            recorder?.append(frame, background: background, metrics: metrics)
            onFrame?(image, frame, metrics, recorder?.frameCount ?? 0)
            onProcessed?()
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
