"""MediaPipe landmark sidecar（1人 / 複数人）.

Protocol (binary stdin / text stdout):
  stdin  : [uint32 BE payload_len][uint64 BE timestamp_ms][JPEG bytes]
           payload_len == 0 は制御メッセージ．timestamp_ms がモード番号（1: 1人，2: 複数人）
  stdout : one JSON object per line
           {"t": timestamp_ms,
            "pose": [[x,y,z,vis]*33] | [], "pose_world": [[x,y,z]*33] | [],
            "face": [[x,y,z]*478] | [], "lh": [[x,y,z]*21] | [], "rh": [[x,y,z]*21] | [],
            "people": [ {同じキー} , ... ]   # 複数人モードのみ．中央の人物を除く他の人物
           }
           pose / face / lh / rh は「画面中央に最も近い人物」（複数人モード）または検出した1人（1人モード）．
  起動時に {"ready": true}，モード切り替え完了時に {"mode": 1|2} を出す．

1人モードは Holistic Landmarker．複数人モードは YOLO（yolo11n）で人物の枠を検出・追跡し，
人物ごとに切り出して Holistic Landmarker を適用する（出力形式は1人モードと同じ）．
"""
import json
import math
import os
import struct
import sys
import urllib.request

import cv2
import numpy as np
import mediapipe as mp
from mediapipe.tasks.python import BaseOptions, vision

MODEL_BASE = "https://storage.googleapis.com/mediapipe-models/"
MODELS = {
    "holistic_landmarker.task": MODEL_BASE + "holistic_landmarker/holistic_landmarker/float16/latest/holistic_landmarker.task",
}
# YOLO の重み（yolo11n.pt）は ultralytics が同じ場所へ自動でダウンロードする
MAX_PEOPLE = 4

MODE_SINGLE = 1
MODE_MULTI = 2


def model_path(name: str) -> str:
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", name)
    if os.path.exists(here):
        return here
    support = os.path.expanduser("~/Library/Application Support/MotionLandmarker/models")
    os.makedirs(support, exist_ok=True)
    path = os.path.join(support, name)
    if not os.path.exists(path) and name in MODELS:
        print(f"downloading {name}...", file=sys.stderr, flush=True)
        urllib.request.urlretrieve(MODELS[name], path)
    return path   # MODELS に無いもの（YOLO の重み）は呼び出し側がダウンロードする


def norm(lms, with_vis: bool):
    if with_vis:
        return [[l.x, l.y, l.z, l.visibility or 0.0] for l in lms]
    return [[l.x, l.y, l.z] for l in lms]


def empty_person():
    return {"pose": [], "pose_world": [], "face": [], "lh": [], "rh": []}


class SingleDetector:
    """Holistic Landmarker（1人）"""

    def __init__(self):
        self.lm = vision.HolisticLandmarker.create_from_options(vision.HolisticLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=model_path("holistic_landmarker.task")),
            running_mode=vision.RunningMode.VIDEO,
        ))

    def detect(self, image, ts):
        r = self.lm.detect_for_video(image, ts)
        return {
            "pose": norm(r.pose_landmarks, True),
            "pose_world": norm(r.pose_world_landmarks, False),
            "face": norm(r.face_landmarks, False),
            "lh": norm(r.left_hand_landmarks, False),
            "rh": norm(r.right_hand_landmarks, False),
        }, []

    def close(self):
        self.lm.close()


class MultiDetector:
    """YOLO で人物の枠を検出し，人物ごとに切り出して Holistic Landmarker を適用する（複数人）。

    ランドマークの精度と出力形式は 1 人モードと同じ（33 点 + ワールド座標 + 顔 478 点 + 手 21 点）。
    Holistic は VIDEO モードで前フレームの状態を使うため，YOLO の追跡 ID ごとに別のインスタンスを持つ。
    """

    # 切り出し枠の余白（枠の幅・高さに対する比）
    CROP_MARGIN = 0.25
    # YOLO の信頼度がこれ未満の枠は無視
    MIN_CONF = 0.4
    # 枠の高さが画面の高さに対してこれ未満の人は「後ろにいる」とみなして除く
    MIN_BOX_HEIGHT = 0.25
    # 使わなくなった追跡 ID の Holistic を捨てるまでのフレーム数
    STALE_FRAMES = 30
    # Holistic（VIDEO モード）は入力サイズが変わると落ちるため，切り出しはこの正方形に
    # 縦横比を保って収める（余白は黒）
    CANVAS = 512

    def __init__(self):
        from ultralytics import YOLO
        import torch
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.yolo = YOLO(model_path("yolo11n.pt"))
        self.holistics = {}   # track_id -> (HolisticLandmarker, last_seen_frame)
        self.frame_no = 0

    def _holistic(self, track_id):
        entry = self.holistics.get(track_id)
        if entry is None:
            lm = vision.HolisticLandmarker.create_from_options(vision.HolisticLandmarkerOptions(
                base_options=BaseOptions(model_asset_path=model_path("holistic_landmarker.task")),
                running_mode=vision.RunningMode.VIDEO,
            ))
            entry = [lm, self.frame_no]
            self.holistics[track_id] = entry
        entry[1] = self.frame_no
        return entry[0]

    def _drop_stale(self):
        for tid in [t for t, (_, seen) in self.holistics.items() if self.frame_no - seen > self.STALE_FRAMES]:
            self.holistics.pop(tid)[0].close()

    def detect(self, image, ts):
        self.frame_no += 1
        rgb = image.numpy_view()
        h, w = rgb.shape[:2]
        # YOLO の追跡（person クラスのみ）。BGR 入力を想定しているので変換する
        res = self.yolo.track(rgb[:, :, ::-1], persist=True, classes=[0], conf=self.MIN_CONF,
                              device=self.device, verbose=False, imgsz=640)[0]
        people = []
        if res.boxes is not None and len(res.boxes) > 0:
            boxes = res.boxes.xyxy.cpu().numpy()
            ids = res.boxes.id.cpu().numpy().astype(int) if res.boxes.id is not None else range(len(boxes))
            confs = res.boxes.conf.cpu().numpy()
            for (x1, y1, x2, y2), tid, conf in zip(boxes, ids, confs):
                bh = (y2 - y1) / h
                if bh < self.MIN_BOX_HEIGHT:
                    continue
                # 余白付きで切り出す
                mw, mh = (x2 - x1) * self.CROP_MARGIN, (y2 - y1) * self.CROP_MARGIN
                cx1, cy1 = int(max(0, x1 - mw)), int(max(0, y1 - mh))
                cx2, cy2 = int(min(w, x2 + mw)), int(min(h, y2 + mh))
                if cx2 - cx1 < 32 or cy2 - cy1 < 32:
                    continue
                crop = rgb[cy1:cy2, cx1:cx2]
                ch, cw = crop.shape[:2]
                scale = self.CANVAS / max(cw, ch)
                rw, rh = max(1, int(round(cw * scale))), max(1, int(round(ch * scale)))
                canvas = np.zeros((self.CANVAS, self.CANVAS, 3), dtype=np.uint8)
                canvas[:rh, :rw] = cv2.resize(crop, (rw, rh), interpolation=cv2.INTER_AREA)
                r = self._holistic(int(tid)).detect_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=canvas), ts)
                if not r.pose_landmarks:
                    continue
                # キャンバスの正規化座標 → 元画像の正規化座標
                #   キャンバス px = l.x * CANVAS，切り出し px = / scale，元画像 px = + cx1，正規化 = / w
                kx = self.CANVAS / scale / w
                ky = self.CANVAS / scale / h
                ox, oy = cx1 / w, cy1 / h

                def to_full(lms, with_vis):
                    # z は x と同じ尺度（キャンバス幅基準）なので同じ比で直す
                    if with_vis:
                        return [[ox + l.x * kx, oy + l.y * ky, l.z * kx, l.visibility or 0.0] for l in lms]
                    return [[ox + l.x * kx, oy + l.y * ky, l.z * kx] for l in lms]

                p = empty_person()
                p["pose"] = to_full(r.pose_landmarks, True)
                p["pose_world"] = norm(r.pose_world_landmarks, False)
                p["face"] = to_full(r.face_landmarks, False)
                p["lh"] = to_full(r.left_hand_landmarks, False)
                p["rh"] = to_full(r.right_hand_landmarks, False)
                p["_cx"] = (x1 + x2) / 2 / w
                people.append(p)
        self._drop_stale()

        if not people:
            return empty_person(), []
        # 中央の人物：枠の中心 x が 0.5 に最も近い人
        people.sort(key=lambda p: abs(p["_cx"] - 0.5))
        for p in people:
            p.pop("_cx", None)
        if len(people) > MAX_PEOPLE:
            people = people[:MAX_PEOPLE]
        return people[0], people[1:]

    def close(self):
        for lm, _ in self.holistics.values():
            lm.close()
        self.holistics.clear()


def create_detector(mode):
    return MultiDetector() if mode == MODE_MULTI else SingleDetector()


def main() -> None:
    # プロトコル用の標準出力を確保し，ライブラリ（ultralytics など）の print は標準エラーへ逃がす
    out = sys.stdout
    sys.stdout = sys.stderr
    os.environ.setdefault("YOLO_VERBOSE", "False")
    mode = MODE_SINGLE
    detector = create_detector(mode)
    stdin = sys.stdin.buffer
    out.write(json.dumps({"ready": True}) + "\n")
    out.flush()

    last_ts = -1
    # VIDEO モードは前フレームの状態を持ち越すため，入力画像のサイズが変わると落ちる．
    # サイズが変わったら検出器を作り直す．
    last_shape = None
    while True:
        header = stdin.read(12)
        if len(header) < 12:
            break
        length, ts = struct.unpack(">IQ", header)

        if length == 0:
            # 制御メッセージ：モード切り替え
            new_mode = int(ts)
            if new_mode in (MODE_SINGLE, MODE_MULTI) and new_mode != mode:
                print(f"switching mode {mode} -> {new_mode}", file=sys.stderr, flush=True)
                detector.close()
                mode = new_mode
                detector = create_detector(mode)
                last_shape = None
            out.write(json.dumps({"mode": mode}) + "\n")
            out.flush()
            continue

        payload = stdin.read(length)
        if len(payload) < length:
            break
        ts = max(int(ts), last_ts + 1)  # VIDEO mode requires monotonic timestamps
        last_ts = ts
        bgr = cv2.imdecode(np.frombuffer(payload, np.uint8), cv2.IMREAD_COLOR)
        if bgr is None:
            # 復号できないフレームでも必ず 1 行返す（呼び出し側が結果を待っているため）
            out.write(json.dumps({"t": ts, **empty_person()}, separators=(",", ":")) + "\n")
            out.flush()
            continue
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        if last_shape is not None and rgb.shape[:2] != last_shape:
            print(f"input size changed {last_shape} -> {rgb.shape[:2]}; recreating detector",
                  file=sys.stderr, flush=True)
            detector.close()
            detector = create_detector(mode)
        last_shape = rgb.shape[:2]
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        center, others = detector.detect(image, ts)
        result = {"t": ts, **center}
        if mode == MODE_MULTI:
            result["people"] = others
        out.write(json.dumps(result, separators=(",", ":")) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
