//
//  LandmarkFrame.swift
//  MotionLandmarker
//
//  MediaPipe Holistic の推論結果（1フレーム分）。座標は画像幅・高さで正規化された [0,1] 値。
//

import Foundation

nonisolated struct Landmark: Sendable {
    var x: Double
    var y: Double
    var z: Double
    var visibility: Double

    init(x: Double, y: Double, z: Double, visibility: Double = 1) {
        self.x = x; self.y = y; self.z = z; self.visibility = visibility
    }
}

nonisolated struct LandmarkFrame: Sendable {
    /// サイドカーに送った時刻 (ms)。キャプチャ開始からの経過時間。
    var timestampMs: Int
    var pose: [Landmark]        // 33 点 or 空（画像で正規化した座標）
    var poseWorld: [Landmark]   // 33 点 or 空（腰の中心を原点とするメートル単位の 3 次元座標）
    var face: [Landmark]        // 478 点 or 空
    var leftHand: [Landmark]    // 21 点 or 空（本人の左手）
    var rightHand: [Landmark]   // 21 点 or 空（本人の右手）

    static let poseCount = 33
    static let faceCount = 478
    static let handCount = 21

    /// サイドカーから受け取った 1 行の JSON を解析する。`{"ready":true}` の場合は nil。
    init?(jsonLine: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
              let t = obj["t"] as? Int else { return nil }
        timestampMs = t
        pose = Self.parse(obj["pose"])
        poseWorld = Self.parse(obj["pose_world"])
        face = Self.parse(obj["face"])
        leftHand = Self.parse(obj["lh"])
        rightHand = Self.parse(obj["rh"])
    }

    private static func parse(_ value: Any?) -> [Landmark] {
        guard let rows = value as? [[NSNumber]] else { return [] }
        return rows.map { r in
            Landmark(x: r[0].doubleValue, y: r[1].doubleValue, z: r[2].doubleValue,
                     visibility: r.count > 3 ? r[3].doubleValue : 1)
        }
    }
}

// MARK: - 骨格の接続定義（MediaPipe 準拠）

nonisolated enum LandmarkTopology {
    /// pose の手首（15, 16）とその先（17〜22）は描画しない（video2landmark の draw_video.py と同じ規則）。
    /// pose と hand は別モデルが独立に推定していて手首の座標が一致しないため，
    /// 前腕は pose の肘から hand の手首（hand 0）へ引き直す。hand が無い側は前腕を描かない。
    static let poseConnections: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 7), (0, 4), (4, 5), (5, 6), (6, 8), (9, 10),
        (11, 12), (11, 13),
        (12, 14),
        (11, 23), (12, 24), (23, 24), (23, 25), (24, 26), (25, 27), (26, 28),
        (27, 29), (28, 30), (29, 31), (30, 32), (27, 31), (28, 32),
    ]
    static let poseHidden: Set<Int> = Set(15...22)
    static let poseShoulder: (left: Int, right: Int) = (11, 12)
    static let poseElbow: (left: Int, right: Int) = (13, 14)

    static let handConnections: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (17, 18), (18, 19), (19, 20), (0, 17),
    ]

    /// 顔の輪郭（FACEMESH_FACE_OVAL）
    static let faceOval: [Int] = [
        10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379,
        378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
        162, 21, 54, 103, 67, 109, 10,
    ]
}
