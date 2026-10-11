"""ランドマークのデータ構造と接続定義（Swift 版 LandmarkFrame.swift と同じ規則）."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

POSE_COUNT = 33
FACE_COUNT = 478
HAND_COUNT = 21


@dataclass
class Person:
    """1 人分のランドマーク．各配列は (N, 3) または pose は (33, 4)（x, y, z, visibility）．未検出は空配列．"""
    pose: np.ndarray = field(default_factory=lambda: np.zeros((0, 4), np.float64))
    pose_world: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float64))
    face: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float64))
    left_hand: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float64))
    right_hand: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float64))

    @property
    def has_pose(self) -> bool: return len(self.pose) == POSE_COUNT
    @property
    def has_face(self) -> bool: return len(self.face) == FACE_COUNT
    @property
    def has_left(self) -> bool: return len(self.left_hand) == HAND_COUNT
    @property
    def has_right(self) -> bool: return len(self.right_hand) == HAND_COUNT


@dataclass
class Frame:
    """1 フレームの検出結果．`person` は中央の人物（1 人モードでは検出した 1 人），`others` は他の人物．"""
    timestamp_ms: int
    person: Person = field(default_factory=Person)
    others: list[Person] = field(default_factory=list)


# --- 接続定義（MediaPipe 準拠．pose は video2landmark の draw_video.py と同じ規則） ---

HAND_CONNECTIONS = [
    (0, 1), (1, 2), (2, 3), (3, 4),
    (0, 5), (5, 6), (6, 7), (7, 8),
    (5, 9), (9, 10), (10, 11), (11, 12),
    (9, 13), (13, 14), (14, 15), (15, 16),
    (13, 17), (17, 18), (18, 19), (19, 20), (0, 17),
]

# pose の手首（15, 16）とその先（17〜22）は描画しない．前腕は肘から hand の手首（hand 0）へ引き直す
POSE_CONNECTIONS = [
    (0, 1), (1, 2), (2, 3), (3, 7), (0, 4), (4, 5), (5, 6), (6, 8), (9, 10),
    (11, 12), (11, 13),
    (12, 14),
    (11, 23), (12, 24), (23, 24), (23, 25), (24, 26), (25, 27), (26, 28),
    (27, 29), (28, 30), (29, 31), (30, 32), (27, 31), (28, 32),
]
POSE_HIDDEN = set(range(15, 23))
POSE_SHOULDER = {"left": 11, "right": 12}
POSE_ELBOW = {"left": 13, "right": 14}

FACE_OVAL = [
    10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379,
    378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
    162, 21, 54, 103, 67, 109, 10,
]
