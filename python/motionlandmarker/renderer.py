"""ランドマークの描画（Swift 版 SkeletonRenderer.swift / Palette の移植）．OpenCV で BGR 画像に描く．"""
from __future__ import annotations

from dataclasses import dataclass, replace

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
    # 複数人モードの人物番号ごとの色（全体映像の枠とタイルの見出しで共通．1 人目から順に）
    slots = [(0.2, 0.75, 1.0), (1.0, 0.8, 0.2), (0.75, 0.45, 1.0), (0.3, 0.9, 0.6), (1.0, 0.45, 0.65)]

    @staticmethod
    def for_slot(slot: int) -> tuple[float, float, float]:
        return Palette.slots[(slot - 1) % len(Palette.slots)]

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


# ---------------------------------------------------------------- 複数人モードのタイル

TILE_MARGIN = 0.08       # 人物の枠の周りに足す余白（枠の幅・高さに対する割合）
TILE_HEIGHT = 360        # タイル画像の高さ（固定．幅は縦横比から決まる）
TILE_ASPECT = 0.75       # タイルの縦横比（幅 / 高さ）の既定値．表示側のマスに合わせて渡す


@dataclass
class Tile:
    """人物ごとの Box．image は人物の枠で切り出した BGR 画像（その人の骨格を表示モードで描いたもの）."""
    slot: int
    bbox: tuple[float, float, float, float]     # 元画像に対する正規化 x, y, w, h（全体映像の枠の描画用）
    image: np.ndarray


def crop_rect(bbox: tuple[float, float, float, float], size: tuple[int, int],
              aspect: float = TILE_ASPECT) -> tuple[int, int, int, int] | None:
    """正規化 bbox に余白を足し，中心を保ったまま縦横比 aspect（幅 / 高さ）に広げて画素の (x1, y1, x2, y2) にする．

    検出した枠の縦横比はフレームごとに変わるが，切り出しを表示のマスと同じ縦横比にそろえることで，
    タイルの映像がマスいっぱいに収まり，大きさが揺れない．画像の外にはみ出す部分はそのまま返す（切り出し側で塗る）．
    小さすぎれば None.
    """
    w, h = size
    x, y, bw, bh = bbox
    cw, ch = bw * (1 + 2 * TILE_MARGIN) * w, bh * (1 + 2 * TILE_MARGIN) * h
    if cw < 4 or ch < 4:
        return None
    if cw / ch < aspect:
        cw = ch * aspect
    else:
        ch = cw / aspect
    cx, cy = (x + bw / 2) * w, (y + bh / 2) * h
    x1, y1 = int(round(cx - cw / 2)), int(round(cy - ch / 2))
    return x1, y1, x1 + int(round(cw)), y1 + int(round(ch))


def _crop(background: np.ndarray, rect: tuple[int, int, int, int], fill) -> np.ndarray:
    """rect を切り出す．画像の外の部分は fill で塗る."""
    x1, y1, x2, y2 = rect
    h, w = background.shape[:2]
    img = np.empty((y2 - y1, x2 - x1, 3), np.uint8)
    img[:] = fill
    sx1, sy1, sx2, sy2 = max(0, x1), max(0, y1), min(w, x2), min(h, y2)
    if sx2 > sx1 and sy2 > sy1:
        img[sy1 - y1:sy2 - y1, sx1 - x1:sx2 - x1] = background[sy1:sy2, sx1:sx2]
    return img


def _person_in_rect(p: Person, rect: tuple[int, int, int, int], size: tuple[int, int]) -> Person:
    """正規化座標を切り出し範囲に対する正規化座標へ変換した Person を返す（z は描画に使わない）."""
    w, h = size
    x1, y1, x2, y2 = rect
    sx, sy = w / (x2 - x1), h / (y2 - y1)
    ox, oy = x1 / w, y1 / h

    def conv(a: np.ndarray) -> np.ndarray:
        if not len(a):
            return a
        b = a.copy()
        b[:, 0] = (b[:, 0] - ox) * sx
        b[:, 1] = (b[:, 1] - oy) * sy
        return b
    return replace(p, pose=conv(p.pose), face=conv(p.face), left_hand=conv(p.left_hand), right_hand=conv(p.right_hand))


def person_tiles(people: list[Person], background: np.ndarray | None, size: tuple[int, int], style: str,
                 options: DrawOptions = ALL, aspect: float = TILE_ASPECT) -> list[Tile]:
    """人物番号のある人物ごとに Box を作る（番号順）．画像は縦横比 aspect，高さ TILE_HEIGHT の固定サイズ．

    style は表示モード（raw | skeleton | overlay）．raw は切り出しのみ，skeleton はスケッチ背景にその人の骨格，
    overlay は切り出した映像にその人の骨格を描く．background が無ければスケッチ背景を使う．
    """
    tiles: list[Tile] = []
    for p in sorted(people, key=lambda q: q.slot):
        if p.slot <= 0 or p.bbox is None:
            continue
        rect = crop_rect(p.bbox, size, aspect)
        if rect is None:
            continue
        x1, y1, x2, y2 = rect
        out = (max(1, int(round(TILE_HEIGHT * aspect))), TILE_HEIGHT)
        if style == "skeleton" or background is None:
            img = np.empty((out[1], out[0], 3), np.uint8)
            img[:] = _bgr(*Palette.sketch_bg)
        else:
            img = _crop(background, rect, (0, 0, 0))
            img = cv2.resize(img, out, interpolation=cv2.INTER_AREA if img.shape[0] > TILE_HEIGHT else cv2.INTER_LINEAR)
        if style != "raw":
            draw_person(img, _person_in_rect(p, rect, size), options)
        tiles.append(Tile(p.slot, p.bbox, img))
    return tiles
