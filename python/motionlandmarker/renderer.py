"""ランドマークの描画（Swift 版 SkeletonRenderer.swift / Palette の移植）．OpenCV で BGR 画像に描く．"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .landmarks import (Frame, Person, HAND_CONNECTIONS, POSE_CONNECTIONS, POSE_HIDDEN,
                        POSE_ELBOW, FACE_OVAL)


def _bgr(r: float, g: float, b: float) -> tuple[int, int, int]:
    return (int(b * 255), int(g * 255), int(r * 255))


class Palette:
    """映像のランドマークとグラフの線で共通に使う色（RGB 0..1）."""
    face = (0.4, 0.85, 1.0)
    face_alt1 = (0.45, 0.55, 1.0)
    face_alt2 = (0.8, 0.55, 1.0)
    body = (1.0, 0.35, 0.35)
    body_alt = (1.0, 0.6, 0.75)
    body_line = (1.0, 1.0, 1.0)
    left_hand = (0.35, 0.9, 0.45)
    right_hand = (1.0, 0.7, 0.2)
    sketch_bg = (0.08, 0.09, 0.11)

    @staticmethod
    def for_kind(kind: str) -> tuple[float, float, float]:
        return {
            "faceYaw": Palette.face, "facePitch": Palette.face_alt1, "faceRoll": Palette.face_alt2,
            "bodyYaw": Palette.body, "bodyRoll": Palette.body_alt,
        }.get(kind, Palette.left_hand if kind.startswith("left") else Palette.right_hand)


@dataclass
class DrawOptions:
    face: bool = True
    pose: bool = True
    left_hand: bool = True
    right_hand: bool = True


ALL = DrawOptions()


def _pt(a: np.ndarray, i: int, w: int, h: int) -> tuple[int, int]:
    return (int(a[i, 0] * w), int(a[i, 1] * h))


def draw_person(img: np.ndarray, p: Person, options: DrawOptions = ALL) -> None:
    h, w = img.shape[:2]
    scale = max(1.0, min(w, h) / 720)
    L = cv2.LINE_AA

    if options.face and p.has_face:
        col = _bgr(*Palette.face)
        pts = np.array([_pt(p.face, i, w, h) for i in FACE_OVAL], np.int32)
        cv2.polylines(img, [pts], False, col, max(1, int(round(1.5 * scale))), L)
        r = max(1, int(round(1.2 * scale)))
        for x, y in (p.face[:, :2] * (w, h)).astype(np.int32):
            cv2.circle(img, (int(x), int(y)), r, col, -1, L)

    if options.pose and p.has_pose:
        line = _bgr(*Palette.body_line)
        t = max(1, int(round(4 * scale)))
        for a, b in POSE_CONNECTIONS:
            if p.pose[a, 3] > 0.5 and p.pose[b, 3] > 0.5:
                cv2.line(img, _pt(p.pose, a, w, h), _pt(p.pose, b, w, h), line, t, L)
        # 前腕：pose の肘 → hand の手首．hand が無い側は描かない
        for side, hand in (("left", p.left_hand if p.has_left else None),
                           ("right", p.right_hand if p.has_right else None)):
            if hand is None:
                continue
            e = POSE_ELBOW[side]
            if p.pose[e, 3] > 0.5:
                cv2.line(img, _pt(p.pose, e, w, h), _pt(hand, 0, w, h), line, t, L)
        joint = _bgr(*Palette.body)
        r = max(1, int(round(5 * scale)))
        for i in range(len(p.pose)):
            if p.pose[i, 3] > 0.5 and i not in POSE_HIDDEN:
                cv2.circle(img, _pt(p.pose, i, w, h), r, joint, -1, L)

    for on, hand, color in ((options.left_hand, p.left_hand if p.has_left else None, Palette.left_hand),
                            (options.right_hand, p.right_hand if p.has_right else None, Palette.right_hand)):
        if not on or hand is None:
            continue
        col = _bgr(*color)
        t = max(1, int(round(3 * scale)))
        for a, b in HAND_CONNECTIONS:
            cv2.line(img, _pt(hand, a, w, h), _pt(hand, b, w, h), col, t, L)
        r = max(1, int(round(3.5 * scale)))
        for i in range(len(hand)):
            cv2.circle(img, _pt(hand, i, w, h), r, col, -1, L)


def compose(frame: Frame | None, background: np.ndarray | None, size: tuple[int, int],
            options: DrawOptions = ALL) -> np.ndarray:
    """背景（BGR）またはスケッチ背景の上にランドマークを描いた BGR 画像を返す（size は (w, h)）."""
    w, h = size
    if background is not None:
        img = background.copy()
    else:
        img = np.empty((h, w, 3), np.uint8)
        img[:] = _bgr(*Palette.sketch_bg)
    if frame is None:
        return img
    if frame.others:
        # 複数人モード：中央の人物以外は半透明で描く
        layer = img.copy()
        for o in frame.others:
            draw_person(layer, o, options)
        cv2.addWeighted(layer, 0.55, img, 0.45, 0, img)
    draw_person(img, frame.person, options)
    return img
