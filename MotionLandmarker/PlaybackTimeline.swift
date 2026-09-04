//
//  PlaybackTimeline.swift
//  MotionLandmarker
//
//  録画を再生するときに波形を出すための，指標の時系列。
//  動画ファイルの場所から同じ録画の CSV を探して読む。
//

import Foundation

nonisolated struct PlaybackTimeline: Sendable {
    /// 各フレームの timestamp_ms（録画時のカメラセッション基準）
    let timestamps: [Int]
    /// 指標ごとの値（timestamps と同じ長さ，未検出は nil）
    let values: [MetricKind: [Float?]]

    var isEmpty: Bool { timestamps.isEmpty }
    /// 動画の先頭フレームの timestamp_ms。動画の再生位置 0 秒に対応する。
    var firstTimestamp: Int { timestamps.first ?? 0 }

    /// 動画ファイル（video_overlay / video_raw / video_skeleton のいずれか）から同じ録画の CSV を探す
    static func load(forVideo url: URL) -> PlaybackTimeline? {
        // .../results_data/video_overlay/{stem}_overlay.mp4 → stem, root
        let name = url.deletingPathExtension().lastPathComponent
        var stem = name
        for suffix in ["_overlay", "_raw", "_skeleton"] where name.hasSuffix(suffix) {
            stem = String(name.dropLast(suffix.count))
        }
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let csvDir = root.appendingPathComponent("csv").appendingPathComponent(stem)
        let metricsURL = csvDir.appendingPathComponent("\(stem)_metrics.csv")
        if let t = loadMetricsCSV(metricsURL) { return t }
        return computeFromLandmarkCSV(directory: csvDir, stem: stem)
    }

    /// 録画時に保存した metrics CSV を読む
    static func loadMetricsCSV(_ url: URL) -> PlaybackTimeline? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard header.count >= 2, header[0] == "frame", header[1] == "timestamp_ms" else { return nil }
        let kinds: [MetricKind?] = header.dropFirst(2).map { MetricKind(rawValue: $0) }
        var timestamps: [Int] = []
        var values: [MetricKind: [Float?]] = [:]
        for k in MetricKind.allCases { values[k] = [] }
        for line in lines {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count == header.count, let ts = Int(cols[1]) else { continue }
            timestamps.append(ts)
            var row: [MetricKind: Float] = [:]
            for (i, k) in kinds.enumerated() {
                guard let k, let v = Float(cols[i + 2]) else { continue }
                row[k] = v
            }
            for k in MetricKind.allCases { values[k]!.append(row[k]) }
        }
        return PlaybackTimeline(timestamps: timestamps, values: values)
    }

    /// metrics CSV が無い録画向け：pose / face / hand の CSV からランドマークを復元して指標を計算する。
    /// pose のワールド座標は CSV に無いため，体のヨーは出ない。
    static func computeFromLandmarkCSV(directory: URL, stem: String) -> PlaybackTimeline? {
        guard let pose = readRows(directory.appendingPathComponent("\(stem)_pose.csv")),
              let face = readRows(directory.appendingPathComponent("\(stem)_face.csv")),
              let hand = readRows(directory.appendingPathComponent("\(stem)_hand.csv")) else { return nil }
        let n = min(pose.count, face.count, hand.count)
        guard n > 0 else { return nil }

        func points(_ cols: [Substring], from: Int, count: Int, stride: Int) -> [Landmark] {
            var out: [Landmark] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                let b = from + i * stride
                guard b + 2 < cols.count, let x = Double(cols[b]), let y = Double(cols[b + 1]),
                      let z = Double(cols[b + 2]) else { return [] }
                let vis = stride > 3 ? (Double(cols[b + 3]) ?? 1) : 1
                out.append(Landmark(x: x, y: y, z: z, visibility: vis))
            }
            return out
        }

        var timestamps: [Int] = []
        var values: [MetricKind: [Float?]] = [:]
        for k in MetricKind.allCases { values[k] = [] }
        var previous: LandmarkFrame?
        for i in 0..<n {
            guard let ts = Int(pose[i][1]) else { continue }
            var frame = LandmarkFrame.empty(timestampMs: ts)
            frame.pose = points(pose[i], from: 2, count: LandmarkFrame.poseCount, stride: 4)
            frame.face = points(face[i], from: 2, count: LandmarkFrame.faceCount, stride: 3)
            frame.leftHand = points(hand[i], from: 2, count: LandmarkFrame.handCount, stride: 3)
            frame.rightHand = points(hand[i], from: 2 + LandmarkFrame.handCount * 3, count: LandmarkFrame.handCount, stride: 3)
            let m = MotionMetrics.compute(frame, previous: previous)
            previous = frame
            timestamps.append(ts)
            for k in MetricKind.allCases { values[k]!.append(m[k].map(Float.init)) }
        }
        return PlaybackTimeline(timestamps: timestamps, values: values)
    }

    private static func readRows(_ url: URL) -> [[Substring]]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    }

    /// 再生位置（動画の秒）までの直近 `window` 秒分を，グラフに渡す形で返す
    func slice(atVideoTime seconds: Double, window: TimeInterval) -> (times: [Date], series: [MetricKind: [Float?]]) {
        let nowMs = firstTimestamp + Int(seconds * 1000)
        let fromMs = nowMs - Int(window * 1000)
        // timestamps は単調増加
        let lo = timestamps.firstIndex { $0 >= fromMs } ?? timestamps.count
        let hi = timestamps.firstIndex { $0 > nowMs } ?? timestamps.count
        guard lo < hi else { return ([], [:]) }
        let times = timestamps[lo..<hi].map { Date(timeIntervalSince1970: Double($0) / 1000) }
        var series: [MetricKind: [Float?]] = [:]
        for (k, arr) in values { series[k] = Array(arr[lo..<hi]) }
        return (times, series)
    }

    /// 再生位置に対応する Date（slice の times と同じ基準）
    func date(atVideoTime seconds: Double) -> Date {
        Date(timeIntervalSince1970: Double(firstTimestamp) / 1000 + seconds)
    }
}
