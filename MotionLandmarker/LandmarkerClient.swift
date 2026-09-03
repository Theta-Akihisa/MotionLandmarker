//
//  LandmarkerClient.swift
//  MotionLandmarker
//
//  Python (uv) で動く MediaPipe Holistic サイドカーの起動と通信。
//  stdin: [uint32 BE len][uint64 BE timestamp_ms][JPEG]
//  stdout: 1 行 1 JSON
//

import Foundation
import CryptoKit

nonisolated enum SidecarError: LocalizedError {
    case uvNotFound
    case bundleMissing
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv が見つかりません。https://docs.astral.sh/uv/ からインストールしてください。"
        case .bundleMissing:
            return "アプリ内に landmarker サイドカーが含まれていません（ビルド設定を確認してください）。"
        case .syncFailed(let log):
            return "Python 依存関係のインストールに失敗しました:\n\(log)"
        }
    }
}

nonisolated enum SidecarBootstrap {
    static let sidecarPathDefaultsKey = "sidecarProjectPath"

    /// uv 実行ファイルを探す（GUI アプリはシェルの PATH を継承しないため明示的に探索）。
    static func locateUV() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/uv",
            "\(home)/.cargo/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// サイドカーのプロジェクトディレクトリを用意する。
    /// UserDefaults に開発用パスが設定されていればそれを使い、無ければバンドル内容を
    /// ~/Library/Application Support/MotionLandmarker/landmarker へ展開する。
    static func prepareProject() throws -> URL {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: sidecarPathDefaultsKey), !custom.isEmpty,
           fm.fileExists(atPath: (custom as NSString).appendingPathComponent("landmarker.py")) {
            return URL(fileURLWithPath: custom)
        }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("landmarker"),
              fm.fileExists(atPath: bundled.appendingPathComponent("landmarker.py").path) else {
            throw SidecarError.bundleMissing
        }
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MotionLandmarker", isDirectory: true)
        let dest = support.appendingPathComponent("landmarker", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let stamp = try contentStamp(of: bundled)
        let stampURL = dest.appendingPathComponent(".stamp")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp { return dest }

        // .venv は残し、それ以外を上書きコピーする
        for item in try fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: item, to: target)
        }
        try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return dest
    }

    private static func contentStamp(of dir: URL) throws -> String {
        var hasher = SHA256()
        for name in ["landmarker.py", "pyproject.toml", "uv.lock"] {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `uv sync` を実行して依存関係を揃える（初回は数十秒かかる）。
    static func sync(uv: URL, project: URL) throws {
        let p = Process()
        p.executableURL = uv
        p.arguments = ["sync", "--project", project.path, "--python", "3.12"]
        p.environment = environment(uv: uv)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw SidecarError.syncFailed(String(data: out, encoding: .utf8) ?? "")
        }
    }

    static func environment(uv: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [uv.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "")]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }
}

/// サイドカープロセスとの通信。スレッドセーフ。
nonisolated final class LandmarkerClient: @unchecked Sendable {
    var onResult: (@Sendable (LandmarkFrame) -> Void)?
    var onReady: (@Sendable () -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var busy = false
    private var running = false
    private var lineBuffer = Data()
    private var stderrLog = ""

    private(set) var isReady = false

    /// 推論中（送ったフレームの結果待ち）かどうか
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    func start(uv: URL, project: URL) throws {
        process.executableURL = uv
        process.arguments = ["run", "--project", project.path, "--python", "3.12", "landmarker.py"]
        process.currentDirectoryURL = project
        process.environment = SidecarBootstrap.environment(uv: uv)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let s = String(data: handle.availableData, encoding: .utf8) else { return }
            self.lock.lock()
            self.stderrLog = String((self.stderrLog + s).suffix(4000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            self.running = false
            self.isReady = false
            let log = self.stderrLog
            self.lock.unlock()
            self.onExit?(p.terminationStatus, log)
        }
        try process.run()
        lock.lock(); running = true; lock.unlock()
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// 推論中でなければフレームを送る。送れなかった場合は false（フレームは捨てる）。
    @discardableResult
    func send(jpeg: Data, timestampMs: Int) -> Bool {
        lock.lock()
        guard running, isReady, !busy else { lock.unlock(); return false }
        busy = true
        lock.unlock()

        var header = Data(capacity: 12)
        var len = UInt32(jpeg.count).bigEndian
        var ts = UInt64(max(0, timestampMs)).bigEndian
        header.append(Data(bytes: &len, count: 4))
        header.append(Data(bytes: &ts, count: 8))
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: header + jpeg)
        } catch {
            lock.lock(); busy = false; lock.unlock()
            return false
        }
        return true
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        if let frame = LandmarkFrame(jsonLine: line) {
            lock.lock(); busy = false; lock.unlock()
            onResult?(frame)
        } else if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["ready"] as? Bool == true {
            lock.lock(); isReady = true; busy = false; lock.unlock()
            onReady?()
        }
    }
}
