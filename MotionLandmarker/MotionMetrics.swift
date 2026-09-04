//
//  MotionMetrics.swift
//  MotionLandmarker
//
//  ランドマークから，グラフ表示用の時系列（顔の向き・体の向き・左右の手腕）を計算する。
//  角度は正規化座標（x, y は画面比，z は x と同スケール）からの推定値 [deg]。
//

import Foundation

/// 波形の表示モード。切り替えボタンで選ぶ。
nonisolated enum MetricMode: String, CaseIterable, Identifiable, Sendable {
    case upperBody, arm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .upperBody: return "上半身"
        case .arm: return "手腕"
        }
    }
    var charts: [MetricChart] { MetricChart.all.filter { $0.mode == self } }
}

/// 1 枚のグラフに重ねて描く系列のまとまり。縦軸の範囲が同じ項目だけをまとめる。
nonisolated struct MetricChart: Identifiable, Sendable {
    let id: String
    let title: String
    let mode: MetricMode
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
        // 上半身
        MetricChart(id: "head", title: "頭の向き [deg]", mode: .upperBody, kinds: [.faceYaw, .facePitch, .faceRoll]),
        MetricChart(id: "body", title: "体の向き [deg]", mode: .upperBody, kinds: [.bodyYaw, .bodyRoll]),
        MetricChart(id: "wristX", title: "手首 x", mode: .upperBody, kinds: [.leftWristX, .rightWristX]),
        MetricChart(id: "wristY", title: "手首 y", mode: .upperBody, kinds: [.leftWristY, .rightWristY]),
        MetricChart(id: "wristSpeed", title: "手首 速度 [/s]", mode: .upperBody, kinds: [.leftWristSpeed, .rightWristSpeed]),
        // 手腕（肘から手まで）
        MetricChart(id: "forearm", title: "前腕の角度 [deg]", mode: .arm, kinds: [.leftForearmAngle, .rightForearmAngle]),
        MetricChart(id: "handDir", title: "手の向き [deg]", mode: .arm, kinds: [.leftHandDirection, .rightHandDirection]),
        MetricChart(id: "handOpen", title: "手の開き", mode: .arm, kinds: [.leftHandOpenness, .rightHandOpenness]),
        MetricChart(id: "armWristSpeed", title: "手首 速度 [/s]", mode: .arm, kinds: [.leftWristSpeed, .rightWristSpeed]),
    ]
}

nonisolated enum MetricKind: String, CaseIterable, Identifiable, Sendable {
    case faceYaw, facePitch, faceRoll
    case bodyYaw, bodyRoll
    case leftWristX, leftWristY, leftWristSpeed
    case rightWristX, rightWristY, rightWristSpeed
    // 手腕モード（肘から手まで）
    case leftForearmAngle, rightForearmAngle
    case leftHandDirection, rightHandDirection
    case leftHandOpenness, rightHandOpenness

    var id: String { rawValue }

    var isLeft: Bool {
        switch self {
        case .leftWristX, .leftWristY, .leftWristSpeed, .leftForearmAngle, .leftHandDirection, .leftHandOpenness:
            return true
        default: return false
        }
    }
    var isRight: Bool {
        switch self {
        case .rightWristX, .rightWristY, .rightWristSpeed, .rightForearmAngle, .rightHandDirection, .rightHandOpenness:
            return true
        default: return false
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
        case .leftForearmAngle: return "左 前腕"
        case .rightForearmAngle: return "右 前腕"
        case .leftHandDirection: return "左 手"
        case .rightHandDirection: return "右 手"
        case .leftHandOpenness: return "左 手"
        case .rightHandOpenness: return "右 手"
        }
    }

    /// グラフの縦軸範囲（固定）。値が最小・最大に追従して波形全体が上下しないようにする。
    var yRange: ClosedRange<Float> {
        switch self {
        case .faceYaw, .facePitch, .faceRoll, .bodyYaw, .bodyRoll: return -90...90
        case .leftWristX, .leftWristY, .rightWristX, .rightWristY: return 0...1
        case .leftWristSpeed, .rightWristSpeed: return 0...5
        case .leftForearmAngle, .rightForearmAngle, .leftHandDirection, .rightHandDirection: return -180...180
        case .leftHandOpenness, .rightHandOpenness: return 0...3
        }
    }

    var unit: String {
        switch self {
        case .faceYaw, .facePitch, .faceRoll, .bodyYaw, .bodyRoll: return "deg"
        case .leftWristSpeed, .rightWristSpeed: return "/s"
        case .leftWristX, .leftWristY, .rightWristX, .rightWristY: return ""
        case .leftForearmAngle, .rightForearmAngle, .leftHandDirection, .rightHandDirection: return "deg"
        case .leftHandOpenness, .rightHandOpenness: return ""
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

        let sides: [(hand: [Landmark], prev: [Landmark]?, elbow: Int,
                     x: MetricKind, y: MetricKind, speed: MetricKind,
                     forearm: MetricKind, direction: MetricKind, openness: MetricKind)] = [
            (frame.leftHand, previous?.leftHand, LandmarkTopology.poseElbow.left,
             .leftWristX, .leftWristY, .leftWristSpeed, .leftForearmAngle, .leftHandDirection, .leftHandOpenness),
            (frame.rightHand, previous?.rightHand, LandmarkTopology.poseElbow.right,
             .rightWristX, .rightWristY, .rightWristSpeed, .rightForearmAngle, .rightHandDirection, .rightHandOpenness),
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

            // 前腕の角度：pose の肘 → hand の手首 の向き（画面上，右向き 0，上向き +90）
            if frame.pose.count == LandmarkFrame.poseCount {
                let elbow = frame.pose[s.elbow]
                if elbow.visibility > 0.5 {
                    v[s.forearm] = deg(atan2(-(wrist.y - elbow.y), wrist.x - elbow.x))
                }
            }
            // 手の向き：手首（0）→ 中指の付け根（9）の向き（右向き 0，上向き +90）
            let mcp = s.hand[9]
            v[s.direction] = deg(atan2(-(mcp.y - wrist.y), mcp.x - wrist.x))
            // 手の開き：各指先（4, 8, 12, 16, 20）から手首までの距離の平均を，手のひらの長さ（0→9）で割った値
            let palm = hypot(mcp.x - wrist.x, mcp.y - wrist.y)
            if palm > 1e-6 {
                let tips = [4, 8, 12, 16, 20].map { hypot(s.hand[$0].x - wrist.x, s.hand[$0].y - wrist.y) }
                v[s.openness] = tips.reduce(0, +) / Double(tips.count) / palm
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
