"""グラフ用の指標（Swift 版 MotionMetrics.swift の移植）．角度は度，座標は正規化座標．"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .landmarks import Frame, Person, POSE_SHOULDER, POSE_ELBOW

# 指標の識別子．metrics CSV の列名と一致させる（Swift 版と同じ順序）
KINDS = [
    "faceYaw", "facePitch", "faceRoll", "bodyYaw", "bodyRoll",
    "leftWristX", "leftWristY", "leftWristSpeed",
    "rightWristX", "rightWristY", "rightWristSpeed",
    "leftForearmAngle", "rightForearmAngle",
    "leftHandDirection", "rightHandDirection",
    "leftHandOpenness", "rightHandOpenness",
]

LABELS = {
    "faceYaw": "ヨー（左右）", "facePitch": "ピッチ（上下）", "faceRoll": "ロール（傾き）",
    "bodyYaw": "ヨー（回転）", "bodyRoll": "ロール（傾き）",
    "leftWristX": "左 手首 x", "leftWristY": "左 手首 y", "leftWristSpeed": "左 手首 速度",
    "rightWristX": "右 手首 x", "rightWristY": "右 手首 y", "rightWristSpeed": "右 手首 速度",
    "leftForearmAngle": "左 前腕", "rightForearmAngle": "右 前腕",
    "leftHandDirection": "左 手", "rightHandDirection": "右 手",
    "leftHandOpenness": "左 手", "rightHandOpenness": "右 手",
}

Y_RANGE = {
    **{k: (-90.0, 90.0) for k in ("faceYaw", "facePitch", "faceRoll", "bodyYaw", "bodyRoll")},
    **{k: (0.0, 1.0) for k in ("leftWristX", "leftWristY", "rightWristX", "rightWristY")},
    **{k: (0.0, 5.0) for k in ("leftWristSpeed", "rightWristSpeed")},
    **{k: (-180.0, 180.0) for k in ("leftForearmAngle", "rightForearmAngle", "leftHandDirection", "rightHandDirection")},
    **{k: (0.0, 3.0) for k in ("leftHandOpenness", "rightHandOpenness")},
}


@dataclass(frozen=True)
class Chart:
    id: str
    title: str
    mode: str          # "upperBody" | "arm"
    kinds: tuple[str, ...]

    @property
    def y_range(self) -> tuple[float, float]:
        lo = min(Y_RANGE[k][0] for k in self.kinds)
        hi = max(Y_RANGE[k][1] for k in self.kinds)
        return lo, hi


CHARTS = [
    Chart("head", "頭の向き [deg]", "upperBody", ("faceYaw", "facePitch", "faceRoll")),
    Chart("body", "体の向き [deg]", "upperBody", ("bodyYaw", "bodyRoll")),
    Chart("wristX", "手首 x", "upperBody", ("leftWristX", "rightWristX")),
    Chart("wristY", "手首 y", "upperBody", ("leftWristY", "rightWristY")),
    Chart("wristSpeed", "手首 速度 [/s]", "upperBody", ("leftWristSpeed", "rightWristSpeed")),
    Chart("forearm", "前腕の角度 [deg]", "arm", ("leftForearmAngle", "rightForearmAngle")),
    Chart("handDir", "手の向き [deg]", "arm", ("leftHandDirection", "rightHandDirection")),
    Chart("handOpen", "手の開き", "arm", ("leftHandOpenness", "rightHandOpenness")),
    Chart("armWristSpeed", "手首 速度 [/s]", "arm", ("leftWristSpeed", "rightWristSpeed")),
]

MODES = {"upperBody": "上半身", "arm": "手腕"}


def charts_for(mode: str) -> list[Chart]:
    return [c for c in CHARTS if c.mode == mode]


def _deg(rad: float) -> float:
    return rad * 180.0 / math.pi


def compute(frame: Frame, previous: Frame | None) -> dict[str, float]:
    """1 フレームの指標．検出されなかった部位に依存する指標は含まれない．"""
    v: dict[str, float] = {}
    p = frame.person

    if p.has_face:
        f = p.face
        l, r, top, chin = f[234], f[454], f[10], f[152]
        v["faceYaw"] = _deg(math.atan2(r[2] - l[2], r[0] - l[0]))
        v["facePitch"] = _deg(math.atan2(chin[2] - top[2], chin[1] - top[1]))
        v["faceRoll"] = _deg(math.atan2(f[263][1] - f[33][1], f[263][0] - f[33][0]))

    # 体の向きはワールド座標（メートル）から．本人の左肩（11）は画面右に写るので「左肩 − 右肩」で取る
    if len(p.pose_world) == 33:
        ls, rs = p.pose_world[POSE_SHOULDER["left"]], p.pose_world[POSE_SHOULDER["right"]]
        v["bodyYaw"] = _deg(math.atan2(ls[2] - rs[2], ls[0] - rs[0]))
        v["bodyRoll"] = _deg(math.atan2(ls[1] - rs[1], ls[0] - rs[0]))
    elif p.has_pose:
        ls, rs = p.pose[POSE_SHOULDER["left"]], p.pose[POSE_SHOULDER["right"]]
        v["bodyRoll"] = _deg(math.atan2(ls[1] - rs[1], ls[0] - rs[0]))

    prev = previous.person if previous is not None else None
    for side, hand, prev_hand in (
        ("left", p.left_hand if p.has_left else None, prev.left_hand if prev is not None and prev.has_left else None),
        ("right", p.right_hand if p.has_right else None, prev.right_hand if prev is not None and prev.has_right else None),
    ):
        if hand is None:
            continue
        wrist = hand[0]
        v[f"{side}WristX"] = float(wrist[0])
        v[f"{side}WristY"] = float(wrist[1])
        if prev_hand is not None and previous is not None and frame.timestamp_ms > previous.timestamp_ms:
            dt = (frame.timestamp_ms - previous.timestamp_ms) / 1000.0
            v[f"{side}WristSpeed"] = math.hypot(wrist[0] - prev_hand[0][0], wrist[1] - prev_hand[0][1]) / dt
        # 前腕の角度：pose の肘 → hand の手首（右向き 0，上向き +90）
        if p.has_pose:
            elbow = p.pose[POSE_ELBOW[side]]
            if elbow[3] > 0.5:
                v[f"{side}ForearmAngle"] = _deg(math.atan2(-(wrist[1] - elbow[1]), wrist[0] - elbow[0]))
        mcp = hand[9]
        v[f"{side}HandDirection"] = _deg(math.atan2(-(mcp[1] - wrist[1]), mcp[0] - wrist[0]))
        palm = math.hypot(mcp[0] - wrist[0], mcp[1] - wrist[1])
        if palm > 1e-6:
            tips = [math.hypot(hand[i][0] - wrist[0], hand[i][1] - wrist[1]) for i in (4, 8, 12, 16, 20)]
            v[f"{side}HandOpenness"] = sum(tips) / len(tips) / palm
    return v


class History:
    """ライブ表示用のリングバッファ．未検出は NaN．先頭要素の通算番号（start_index）を持つ．"""

    def __init__(self, capacity: int = 1200):
        self.capacity = capacity
        self.times = np.zeros(0, np.float64)           # 受信時刻（秒）
        self.values = {k: np.zeros(0, np.float32) for k in KINDS}
        self.start_index = 0

    def push(self, metrics: dict[str, float], t: float):
        self.times = np.append(self.times, t)
        for k in KINDS:
            self.values[k] = np.append(self.values[k], metrics.get(k, np.nan))
        if len(self.times) > self.capacity:
            drop = len(self.times) - self.capacity
            self.times = self.times[drop:]
            for k in KINDS:
                self.values[k] = self.values[k][drop:]
            self.start_index += drop
