//
//  MotionMetrics.swift
//  MotionLandmarker
//
//  ランドマークから，グラフ表示用の時系列（顔の向き・体の向き・左右の手腕）を計算する。
//  角度は正規化座標（x, y は画面比，z は x と同スケール）からの推定値 [deg]。
//

import Foundation

nonisolated enum MetricGroup: String, CaseIterable, Identifiable, Sendable {
    case face, body, leftArm, rightArm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .face: return "頭の向き"
        case .body: return "体の向き"
        case .leftArm: return "左手腕"
        case .rightArm: return "右手腕"
        }
    }
    var kinds: [MetricKind] { MetricKind.allCases.filter { $0.group == self } }
}

/// 1 枚のグラフに重ねて描く系列のまとまり。縦軸の範囲が同じ項目だけをまとめる。
nonisolated struct MetricChart: Identifiable, Sendable {
    let id: String
    let title: String
    let kinds: [MetricKind]
    var unit: String { kinds.first?.unit ?? "" }
    /// 重ねる系列の範囲をすべて含む範囲（縦軸は 1 枚につき 1 つ）
    var yRange: ClosedRange<Float> {
        guard let first = kinds.first?.yRange else { return 0...1 }
        return kinds.dropFirst().reduce(first) { r, k in
            min(r.lowerBound, k.yRange.lowerBound)...max(r.upperBound, k.yRange.upperBound)
        }
    }

    static let all: [MetricChart] = [
        MetricChart(id: "head", title: "頭の向き [deg]", kinds: [.faceYaw, .facePitch, .faceRoll]),
        MetricChart(id: "body", title: "体の向き [deg]", kinds: [.bodyYaw, .bodyRoll]),
        MetricChart(id: "wristX", title: "手首 x", kinds: [.leftWristX, .rightWristX]),
        MetricChart(id: "wristY", title: "手首 y", kinds: [.leftWristY, .rightWristY]),
        MetricChart(id: "wristSpeed", title: "手首 速度 [/s]", kinds: [.leftWristSpeed, .rightWristSpeed]),
    ]
}

nonisolated enum MetricKind: String, CaseIterable, Identifiable, Sendable {
    case faceYaw, facePitch, faceRoll
    case bodyYaw, bodyRoll
    case leftWristX, leftWristY, leftWristSpeed
    case rightWristX, rightWristY, rightWristSpeed

    var id: String { rawValue }

    var group: MetricGroup {
        switch self {
        case .faceYaw, .facePitch, .faceRoll: return .face
        case .bodyYaw, .bodyRoll: return .body
        case .leftWristX, .leftWristY, .leftWristSpeed: return .leftArm
        case .rightWristX, .rightWristY, .rightWristSpeed: return .rightArm
        }
    }

    var label: String {
        switch self {
        case .faceYaw: return "ヨー（左右）"
        case .facePitch: return "ピッチ（上下）"
        case .faceRoll: return "ロール（傾き）"
        case .bodyYaw: return "ヨー（回転）"
        case .bodyRoll: return "ロール（傾き）"
        case .leftWristX: return "左 手首 x"
        case .leftWristY: return "左 手首 y"
        case .leftWristSpeed: return "左 手首 速度"
        case .rightWristX: return "右 手首 x"
        case .rightWristY: return "右 手首 y"
        case .rightWristSpeed: return "右 手首 速度"
        }
    }

    /// グラフの縦軸範囲（固定）。値が最小・最大に追従して波形全体が上下しないようにする。
    var yRange: ClosedRange<Float> {
        switch self {
        case .faceYaw, .facePitch, .faceRoll, .bodyYaw, .bodyRoll: return -90...90
        case .leftWristX, .leftWristY, .rightWristX, .rightWristY: return 0...1
        case .leftWristSpeed, .rightWristSpeed: return 0...5
        }
    }

    var unit: String {
        switch self {
        case .faceYaw, .facePitch, .faceRoll, .bodyYaw, .bodyRoll: return "deg"
        case .leftWristSpeed, .rightWristSpeed: return "/s"
        case .leftWristX, .leftWristY, .rightWristX, .rightWristY: return ""
        }
    }
}

nonisolated enum MotionMetrics {
    /// 検出されなかった部位に依存する指標は含まれない。
    static func compute(_ frame: LandmarkFrame, previous: LandmarkFrame?) -> [MetricKind: Double] {
        var v: [MetricKind: Double] = [:]

        if frame.face.count == LandmarkFrame.faceCount {
            let f = frame.face
            // 234: 左頬側輪郭，454: 右頬側輪郭，10: 額，152: 顎，33 / 263: 目尻
            let l = f[234], r = f[454], top = f[10], chin = f[152]
            v[.faceYaw] = deg(atan2(r.z - l.z, r.x - l.x))
            v[.facePitch] = deg(atan2(chin.z - top.z, chin.y - top.y))
            v[.faceRoll] = deg(atan2(f[263].y - f[33].y, f[263].x - f[33].x))
        }

        // 体の向きはワールド座標（メートル単位）から求める。画像座標の z は精度が低く，
        // 実測で揺れが約 3 倍大きいため。ワールド座標は x: 右+，y: 下+，z: カメラ側+。
        // 正面から撮ると本人の左肩（11）が画面右に写るので，差は「左肩 − 右肩」で取る
        // （逆にすると正面が ±180 になり反転する）。正面で 0。
        if frame.poseWorld.count == LandmarkFrame.poseCount {
            let ls = frame.poseWorld[LandmarkTopology.poseShoulder.left]
            let rs = frame.poseWorld[LandmarkTopology.poseShoulder.right]
            v[.bodyYaw] = deg(atan2(ls.z - rs.z, ls.x - rs.x))
            v[.bodyRoll] = deg(atan2(ls.y - rs.y, ls.x - rs.x))
        } else if frame.pose.count == LandmarkFrame.poseCount {
            let ls = frame.pose[LandmarkTopology.poseShoulder.left]
            let rs = frame.pose[LandmarkTopology.poseShoulder.right]
            v[.bodyRoll] = deg(atan2(ls.y - rs.y, ls.x - rs.x))
        }

        let sides: [(hand: [Landmark], prev: [Landmark]?, x: MetricKind, y: MetricKind, speed: MetricKind)] = [
            (frame.leftHand, previous?.leftHand, .leftWristX, .leftWristY, .leftWristSpeed),
            (frame.rightHand, previous?.rightHand, .rightWristX, .rightWristY, .rightWristSpeed),
        ]
        for s in sides where s.hand.count == LandmarkFrame.handCount {
            let wrist = s.hand[0]
            v[s.x] = wrist.x
            v[s.y] = wrist.y
            if let prev = s.prev, prev.count == LandmarkFrame.handCount,
               let previous, frame.timestampMs > previous.timestampMs {
                let dt = Double(frame.timestampMs - previous.timestampMs) / 1000
                v[s.speed] = hypot(wrist.x - prev[0].x, wrist.y - prev[0].y) / dt
            }
        }
        return v
    }

    private static func deg(_ rad: Double) -> Double { rad * 180 / .pi }
}

/// グラフ用のリングバッファ。
/// 部位が検出されなかったフレームは nil を入れ，グラフではその区間の線を途切れさせる。
nonisolated struct MetricHistory: Sendable {
    let capacity: Int
    private(set) var series: [MetricKind: [Float?]] = [:]
    /// 各サンプルを受け取った時刻（series と同じ長さ）
    private(set) var times: [Date] = []

    init(capacity: Int = 300) {
        self.capacity = capacity
        for k in MetricKind.allCases { series[k] = [] }
    }

    mutating func push(_ values: [MetricKind: Double], at time: Date = Date()) {
        times.append(time)
        if times.count > capacity { times.removeFirst(times.count - capacity) }
        for k in MetricKind.allCases {
            var arr = series[k] ?? []
            arr.append(values[k].map(Float.init))
            if arr.count > capacity { arr.removeFirst(arr.count - capacity) }
            series[k] = arr
        }
    }

    subscript(k: MetricKind) -> [Float?] { series[k] ?? [] }
}
