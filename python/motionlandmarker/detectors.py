"""MediaPipe による検出（1 人 / 複数人）．Swift 版サイドカー landmarker.py の移植．

1 人モードは Holistic Landmarker．複数人モードは YOLO（Ultralytics，任意依存）で人物の枠を
検出・追跡し，人物ごとに切り出して Holistic Landmarker を適用する．
"""
from __future__ import annotations

import os
import sys
import urllib.request
from pathlib import Path

import cv2
import numpy as np

from .landmarks import Frame, Person

MODEL_BASE = "https://storage.googleapis.com/mediapipe-models/"
MODELS = {
    "holistic_landmarker.task": MODEL_BASE + "holistic_landmarker/holistic_landmarker/float16/latest/holistic_landmarker.task",
}
MAX_PEOPLE = 4

MODE_SINGLE = 1
MODE_MULTI = 2


def models_dir() -> Path:
    """モデルの置き場所．パッケージ横の models/ があればそれを，無ければユーザーのデータ領域を使う."""
    here = Path(__file__).resolve().parent.parent / "models"
    if here.is_dir():
        return here
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    d = base / "MotionLandmarker" / "models"
    d.mkdir(parents=True, exist_ok=True)
    return d


def model_path(name: str) -> str:
    path = models_dir() / name
    if not path.exists() and name in MODELS:
        print(f"downloading {name}...", file=sys.stderr, flush=True)
        urllib.request.urlretrieve(MODELS[name], path)
    return str(path)


def _arr(lms, with_vis: bool) -> np.ndarray:
    if not lms:
        return np.zeros((0, 4 if with_vis else 3), np.float64)
    if with_vis:
        return np.array([[l.x, l.y, l.z, l.visibility or 0.0] for l in lms], np.float64)
    return np.array([[l.x, l.y, l.z] for l in lms], np.float64)


def _mp():
    import mediapipe as mp
    from mediapipe.tasks.python import BaseOptions, vision
    return mp, BaseOptions, vision


def _create_holistic():
    mp, BaseOptions, vision = _mp()
    return vision.HolisticLandmarker.create_from_options(vision.HolisticLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=model_path("holistic_landmarker.task")),
        running_mode=vision.RunningMode.VIDEO,
    ))


def _to_person(r, transform=None) -> Person:
    p = Person(
        pose=_arr(r.pose_landmarks, True),
        pose_world=_arr(r.pose_world_landmarks, False),
        face=_arr(r.face_landmarks, False),
        left_hand=_arr(r.left_hand_landmarks, False),
        right_hand=_arr(r.right_hand_landmarks, False),
    )
    if transform is not None:
        for a in (p.pose, p.face, p.left_hand, p.right_hand):
            if len(a):
                transform(a)
    return p


class SingleDetector:
    """Holistic Landmarker（1 人）."""

    def __init__(self):
        self.lm = _create_holistic()

    def detect(self, rgb: np.ndarray, ts: int) -> tuple[Person, list[Person]]:
        mp, _, _ = _mp()
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        return _to_person(self.lm.detect_for_video(image, ts)), []

    def close(self):
        self.lm.close()


class MultiDetector:
    """YOLO で人物の枠を検出・追跡し，人物ごとに切り出して Holistic を適用する（複数人）."""

    CROP_MARGIN = 0.25
    MIN_CONF = 0.4
    MIN_BOX_HEIGHT = 0.25
    STALE_FRAMES = 30
    CANVAS = 512

    def __init__(self):
        try:
            from ultralytics import YOLO
            import torch
        except ImportError as e:
            raise RuntimeError("複数人モードには ultralytics が必要です（uv sync --extra multi）") from e
        os.environ.setdefault("YOLO_VERBOSE", "False")
        if torch.backends.mps.is_available():
            self.device = "mps"
        elif torch.cuda.is_available():
            self.device = "cuda"
        else:
            self.device = "cpu"
        self.yolo = YOLO(str(models_dir() / "yolo11n.pt"))  # 無ければ ultralytics が同じ場所へダウンロードする
        self.holistics: dict[int, list] = {}
        self.frame_no = 0

    def _holistic(self, tid: int):
        entry = self.holistics.get(tid)
        if entry is None:
            entry = [_create_holistic(), self.frame_no]
            self.holistics[tid] = entry
        entry[1] = self.frame_no
        return entry[0]

    def _drop_stale(self):
        for tid in [t for t, (_, seen) in self.holistics.items() if self.frame_no - seen > self.STALE_FRAMES]:
            self.holistics.pop(tid)[0].close()

    def detect(self, rgb: np.ndarray, ts: int) -> tuple[Person, list[Person]]:
        mp, _, _ = _mp()
        self.frame_no += 1
        h, w = rgb.shape[:2]
        res = self.yolo.track(rgb[:, :, ::-1], persist=True, classes=[0], conf=self.MIN_CONF,
                              device=self.device, verbose=False, imgsz=640)[0]
        people: list[tuple[float, Person]] = []
        if res.boxes is not None and len(res.boxes) > 0:
            boxes = res.boxes.xyxy.cpu().numpy()
            ids = res.boxes.id.cpu().numpy().astype(int) if res.boxes.id is not None else range(len(boxes))
            for (x1, y1, x2, y2), tid in zip(boxes, ids):
                if (y2 - y1) / h < self.MIN_BOX_HEIGHT:
                    continue
                mw, mh = (x2 - x1) * self.CROP_MARGIN, (y2 - y1) * self.CROP_MARGIN
                cx1, cy1 = int(max(0, x1 - mw)), int(max(0, y1 - mh))
                cx2, cy2 = int(min(w, x2 + mw)), int(min(h, y2 + mh))
                if cx2 - cx1 < 32 or cy2 - cy1 < 32:
                    continue
                crop = rgb[cy1:cy2, cx1:cx2]
                ch, cw = crop.shape[:2]
                scale = self.CANVAS / max(cw, ch)
                rw, rh = max(1, int(round(cw * scale))), max(1, int(round(ch * scale)))
                canvas = np.zeros((self.CANVAS, self.CANVAS, 3), np.uint8)
                canvas[:rh, :rw] = cv2.resize(crop, (rw, rh), interpolation=cv2.INTER_AREA)
                r = self._holistic(int(tid)).detect_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=canvas), ts)
                if not r.pose_landmarks:
                    continue
                kx, ky = self.CANVAS / scale / w, self.CANVAS / scale / h
                ox, oy = cx1 / w, cy1 / h

                def to_full(a, kx=kx, ky=ky, ox=ox, oy=oy):
                    a[:, 0] = ox + a[:, 0] * kx
                    a[:, 1] = oy + a[:, 1] * ky
                    a[:, 2] = a[:, 2] * kx

                people.append((abs((x1 + x2) / 2 / w - 0.5), _to_person(r, to_full)))
        self._drop_stale()
        if not people:
            return Person(), []
        people.sort(key=lambda t: t[0])
        persons = [p for _, p in people][:MAX_PEOPLE]
        return persons[0], persons[1:]

    def close(self):
        for lm, _ in self.holistics.values():
            lm.close()
        self.holistics.clear()


class Detector:
    """モード切り替えと入力サイズ変化への対応をまとめた検出器．

    VIDEO モードは前フレームの状態を持ち越すため，入力画像のサイズが変わると落ちる．
    サイズが変わったら作り直す．タイムスタンプは単調増加に補正する．
    """

    def __init__(self, mode: int = MODE_SINGLE):
        self.mode = mode
        self._impl = None
        self._last_shape = None
        self._last_ts = -1

    def _ensure(self):
        if self._impl is None:
            self._impl = MultiDetector() if self.mode == MODE_MULTI else SingleDetector()

    def set_mode(self, mode: int):
        if mode != self.mode:
            self.close()
            self.mode = mode

    def detect(self, rgb: np.ndarray, ts: int) -> Frame:
        if self._last_shape is not None and rgb.shape[:2] != self._last_shape:
            self.close()
        self._last_shape = rgb.shape[:2]
        self._ensure()
        ts = max(int(ts), self._last_ts + 1)
        self._last_ts = ts
        person, others = self._impl.detect(np.ascontiguousarray(rgb), ts)
        return Frame(timestamp_ms=ts, person=person, others=others)

    def close(self):
        if self._impl is not None:
            self._impl.close()
            self._impl = None
