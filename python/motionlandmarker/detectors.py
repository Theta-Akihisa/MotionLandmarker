"""MediaPipe による検出（1 人 / 複数人）．Swift 版サイドカー landmarker.py の移植．

1 人モードは Holistic Landmarker．複数人モードは YOLO（Ultralytics，任意依存）で人物の枠を
検出・追跡し，人物ごとに切り出して Holistic Landmarker を適用する．

GPU の使い方:
- Holistic（MediaPipe）の GPU は Linux（Ubuntu）だけが対応．Linux では GPU で作り，作成や推論に失敗したら
  CPU に切り替える（以後は CPU のまま）．Windows / macOS は CPU．環境変数 ML_MP_DELEGATE=auto|gpu|cpu で指定できる．
- YOLO（PyTorch）は CUDA（Windows / Linux），MPS（macOS），CPU の順に使えるものを使う．CUDA では半精度で推論する．
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
MAX_PEOPLE = 5

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


_mp_gpu_failed = False      # Holistic の GPU が一度でも失敗したら以後は CPU で作る


def holistic_delegate() -> str:
    """Holistic に使う演算装置（"gpu" | "cpu"）．MediaPipe の Python 版で GPU が使えるのは Linux だけ."""
    want = os.environ.get("ML_MP_DELEGATE", "auto").lower()
    if want == "cpu" or _mp_gpu_failed:
        return "cpu"
    if want == "gpu":
        return "gpu"
    return "gpu" if sys.platform.startswith("linux") else "cpu"


def _gpu_failed(e: Exception):
    global _mp_gpu_failed
    if not _mp_gpu_failed:
        print(f"MediaPipe の GPU が使えないため CPU に切り替えます: {e}", file=sys.stderr, flush=True)
    _mp_gpu_failed = True


def _create_holistic(delegate: str):
    mp, BaseOptions, vision = _mp()
    d = BaseOptions.Delegate.GPU if delegate == "gpu" else BaseOptions.Delegate.CPU
    return vision.HolisticLandmarker.create_from_options(vision.HolisticLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=model_path("holistic_landmarker.task"), delegate=d),
        running_mode=vision.RunningMode.VIDEO,
    ))


class Holistic:
    """Holistic Landmarker（VIDEO モード）．GPU で作成・推論に失敗したら CPU で作り直して続ける."""

    def __init__(self):
        self.delegate = holistic_delegate()
        try:
            self.lm = _create_holistic(self.delegate)
        except Exception as e:
            if self.delegate != "gpu":
                raise
            _gpu_failed(e)
            self.delegate = "cpu"
            self.lm = _create_holistic("cpu")

    def detect(self, rgb: np.ndarray, ts: int):
        mp, _, _ = _mp()
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        try:
            return self.lm.detect_for_video(image, ts)
        except Exception as e:
            if self.delegate != "gpu":
                raise
            # 作り直した Landmarker はタイムスタンプの履歴を持たないので，同じ ts でやり直せる
            _gpu_failed(e)
            self.close()
            self.delegate = "cpu"
            self.lm = _create_holistic("cpu")
            return self.lm.detect_for_video(image, ts)

    def close(self):
        self.lm.close()


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
        self.lm = Holistic()

    @property
    def accel(self) -> str:
        return f"MediaPipe {self.lm.delegate.upper()}"

    def detect(self, rgb: np.ndarray, ts: int) -> tuple[Person, list[Person]]:
        return _to_person(self.lm.detect(rgb, ts)), []

    def close(self):
        self.lm.close()


class SlotAssigner:
    """追跡 ID（YOLO / ByteTrack）→ 人物番号（1〜MAX_PEOPLE）の対応を保つ．

    番号の決め方:
    - 初めて現れた追跡 ID には，空いている番号のうち最小のものを割り当てる．
    - 一度割り当てた番号は，その ID が見えなくなっても HOLD_FRAMES フレームの間は予約したままにし，
      他の人へは回さない（一時的に見失った人が同じ追跡 ID で戻れば同じ番号になる）．
    - 予約期間を過ぎた番号は空きに戻る．空きが無いときは，今のフレームに映っていない ID のうち
      最も長く見えていないものの番号を譲り受ける（映っている人の番号は奪わない）．
    - 追跡 ID がまだ付いていない検出（負の仮 ID）は予約しない（次のフレームで番号を空ける）．
    追跡器が同じ人に新しい ID を振り直した場合は別人として扱う（新しい番号になる）．
    """

    HOLD_FRAMES = 60

    def __init__(self, max_slots: int = MAX_PEOPLE):
        self.max_slots = max_slots
        self.slots: dict[int, list[int]] = {}   # 追跡 ID -> [人物番号, 最後に見えたフレーム]
        self.frame_no = 0

    def update(self, ids: list[int]) -> dict[int, int]:
        """このフレームに映っている追跡 ID の並びから，ID -> 人物番号 を返す（番号が足りない ID は含まれない）."""
        self.frame_no += 1
        current = set(ids)
        for tid in [t for t, (_, seen) in self.slots.items()
                    if t not in current and (t < 0 or self.frame_no - seen > self.HOLD_FRAMES)]:
            del self.slots[tid]
        out: dict[int, int] = {}
        for tid in ids:
            entry = self.slots.get(tid)
            if entry is None:
                used = {s for s, _ in self.slots.values()}
                free = [s for s in range(1, self.max_slots + 1) if s not in used]
                if free:
                    slot = free[0]
                else:
                    idle = [t for t in self.slots if t not in current]
                    if not idle:
                        continue
                    victim = min(idle, key=lambda t: self.slots[t][1])
                    slot = self.slots.pop(victim)[0]
                entry = self.slots[tid] = [slot, self.frame_no]
            entry[1] = self.frame_no
            out[tid] = entry[0]
        return out


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
        if torch.cuda.is_available():
            self.device = "cuda"
            torch.backends.cudnn.benchmark = True    # 入力サイズが一定なので最速の畳み込みを選ばせる
        elif torch.backends.mps.is_available():
            self.device = "mps"
        else:
            self.device = "cpu"
        self.yolo = YOLO(str(models_dir() / "yolo11n.pt"))  # 無ければ ultralytics が同じ場所へダウンロードする
        self.holistics: dict[int, list] = {}
        self.assigner = SlotAssigner()
        self.frame_no = 0

    @property
    def accel(self) -> str:
        delegates = {h.delegate for h, _ in self.holistics.values()} or {holistic_delegate()}
        return f"MediaPipe {'/'.join(sorted(d.upper() for d in delegates))} · YOLO {self.device.upper()}"

    def _holistic(self, tid: int):
        entry = self.holistics.get(tid)
        if entry is None:
            entry = [Holistic(), self.frame_no]
            self.holistics[tid] = entry
        entry[1] = self.frame_no
        return entry[0]

    def _drop_stale(self):
        for tid in [t for t, (_, seen) in self.holistics.items() if self.frame_no - seen > self.STALE_FRAMES]:
            self.holistics.pop(tid)[0].close()

    def detect(self, rgb: np.ndarray, ts: int) -> tuple[Person, list[Person]]:
        self.frame_no += 1
        h, w = rgb.shape[:2]
        # 検出数は信頼度の高い順に最大 MAX_PEOPLE 人まで
        res = self.yolo.track(rgb[:, :, ::-1], persist=True, classes=[0], conf=self.MIN_CONF,
                              device=self.device, half=self.device == "cuda", verbose=False, imgsz=640,
                              max_det=MAX_PEOPLE)[0]
        people: list[tuple[float, Person, int]] = []
        if res.boxes is not None and len(res.boxes) > 0:
            boxes = res.boxes.xyxy.cpu().numpy()
            # 追跡 ID が未確定のフレームでは負の仮 ID を使う（本物の ID と衝突させない）
            ids = ([int(t) for t in res.boxes.id.cpu().numpy()] if res.boxes.id is not None
                   else [-1 - i for i in range(len(boxes))])
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
                r = self._holistic(int(tid)).detect(canvas, ts)
                if not r.pose_landmarks:
                    continue
                kx, ky = self.CANVAS / scale / w, self.CANVAS / scale / h
                ox, oy = cx1 / w, cy1 / h

                def to_full(a, kx=kx, ky=ky, ox=ox, oy=oy):
                    a[:, 0] = ox + a[:, 0] * kx
                    a[:, 1] = oy + a[:, 1] * ky
                    a[:, 2] = a[:, 2] * kx

                person = _to_person(r, to_full)
                person.bbox = (float(x1 / w), float(y1 / h), float((x2 - x1) / w), float((y2 - y1) / h))
                people.append((abs((x1 + x2) / 2 / w - 0.5), person, tid))
        self._drop_stale()
        # 人物番号は骨格が取れた人物（= Box を出す人物）にだけ割り当てる（取れなかった人は「見えていない」扱い）
        slots = self.assigner.update([tid for _, _, tid in people])
        for _, p, tid in people:
            p.slot = slots.get(tid, 0)
        people = [(c, p) for c, p, _ in people if p.slot > 0]
        if not people:
            return Person(), []
        # 先頭（Frame.person）は従来どおり中央の人物．metrics CSV はこの人物の値
        people.sort(key=lambda t: t[0])
        persons = [p for _, p in people][:MAX_PEOPLE]
        return persons[0], persons[1:]

    def close(self):
        for lm, _ in self.holistics.values():
            lm.close()
        self.holistics.clear()
        self.assigner = SlotAssigner()


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

    @property
    def accel(self) -> str:
        """使っている演算装置の表示（例: "MediaPipe GPU · YOLO CUDA"）．まだ作っていなければ空."""
        return self._impl.accel if self._impl is not None else ""

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
