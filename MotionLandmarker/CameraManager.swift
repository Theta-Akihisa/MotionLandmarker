//
//  CameraManager.swift
//  MotionLandmarker
//
//  カメラのフレームを AVCaptureVideoDataOutput で受け取り，パイプラインへ渡す。
//  （動画の保存は AVCaptureMovieFileOutput ではなく LandmarkRecorder が行う）
//

import Foundation
import Observation
import AVFoundation

@Observable
class CameraManager {
    var currentCameraName = ""
    var canSwitchCamera = false
    var isCameraAvailable = false
    var permissionDenied = false
    /// 選択肢（uniqueID と表示名）。接続・切断で更新される。
    var devices: [(id: String, name: String)] = []
    /// 選択中のカメラの uniqueID。UI から変更すると切り替わる。
    var selectedDeviceID: String = "" {
        didSet {
            guard selectedDeviceID != oldValue, !selectedDeviceID.isEmpty,
                  let device = allVideoDevices.first(where: { $0.uniqueID == selectedDeviceID }) else { return }
            select(device)
        }
    }

    @ObservationIgnored let captureSession = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "camera.session")
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let tap = FrameTap()
    @ObservationIgnored private var allVideoDevices: [AVCaptureDevice] = []
    @ObservationIgnored private var currentDeviceIndex = 0

    /// (BGRA ピクセルバッファ, セッション開始からの経過ミリ秒)
    var onFrame: (@Sendable (CVPixelBuffer, Int) -> Void)? {
        get { tap.onFrame }
        set { tap.onFrame = newValue }
    }

    func start() {
        Task { await configureSession() }
    }

    func stop() {
        sessionQueue.async { [captureSession] in captureSession.stopRunning() }
    }

    private func configureSession() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { permissionDenied = true; return }

        let tap = self.tap
        let videoOutput = self.videoOutput
        let session = self.captureSession
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let devices = Self.discoverVideoDevices()
            guard !devices.isEmpty else { return }

            let device = AVCaptureDevice.systemPreferredCamera
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video)
                ?? devices[0]

            guard let deviceInput = try? AVCaptureDeviceInput(device: device) else { return }

            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            if session.canAddInput(deviceInput) { session.addInput(deviceInput) }
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(tap, queue: DispatchQueue(label: "camera.frames"))
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.commitConfiguration()
            session.startRunning()

            let initialIndex = devices.firstIndex(of: device) ?? 0
            let name = device.localizedName
            let id = device.uniqueID
            let list = devices.map { (id: $0.uniqueID, name: $0.localizedName) }
            Task { @MainActor in
                self.allVideoDevices = devices
                self.currentDeviceIndex = initialIndex
                self.currentCameraName = name
                self.devices = list
                self.selectedDeviceID = id
                self.canSwitchCamera = devices.count > 1
                self.isCameraAvailable = true
            }
        }
        observeDeviceChanges()
    }

    /// カメラの接続・切断で一覧を更新する
    private func observeDeviceChanges() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            }
        }
    }

    func refreshDevices() {
        let found = Self.discoverVideoDevices()
        allVideoDevices = found
        devices = found.map { (id: $0.uniqueID, name: $0.localizedName) }
        canSwitchCamera = found.count > 1
        if !found.contains(where: { $0.uniqueID == selectedDeviceID }), let first = found.first {
            selectedDeviceID = first.uniqueID
        }
    }

    nonisolated private static func discoverVideoDevices() -> [AVCaptureDevice] {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        if !discovered.isEmpty { return discovered }
        if let fallback = AVCaptureDevice.default(for: .video) { return [fallback] }
        return []
    }

    /// 次のカメラへ順送りで切り替える
    func switchCamera() {
        guard canSwitchCamera, allVideoDevices.count > 1 else { return }
        let next = allVideoDevices[(currentDeviceIndex + 1) % allVideoDevices.count]
        selectedDeviceID = next.uniqueID   // didSet で select が呼ばれる
    }

    private func select(_ nextDevice: AVCaptureDevice) {
        currentDeviceIndex = allVideoDevices.firstIndex(of: nextDevice) ?? 0
        let session = captureSession
        sessionQueue.async {
            session.beginConfiguration()
            session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .filter { $0.device.hasMediaType(.video) }
                .forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: nextDevice), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
        currentCameraName = nextDevice.localizedName
    }
}

/// ビデオフレームの受け口。キャプチャ用スレッドで呼ばれるためメインアクタから切り離す。
nonisolated final class FrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _onFrame: (@Sendable (CVPixelBuffer, Int) -> Void)?
    private var startTime: CMTime?

    var onFrame: (@Sendable (CVPixelBuffer, Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    // タイムスタンプの起点は最初のフレームで一度だけ決める。
    // セッションの PTS はカメラ切り替え後も連続するため，切り替え時にリセットしない。

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.lock()
        if startTime == nil { startTime = pts }
        let ms = Int((CMTimeSubtract(pts, startTime!).seconds * 1000).rounded())
        let cb = _onFrame
        lock.unlock()
        cb?(pb, ms)
    }
}
