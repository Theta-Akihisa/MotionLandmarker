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

1人モードは Holistic Landmarker，複数人モードは Pose / Hand / Face Landmarker を組み合わせ，
手と顔を pose の手首・鼻との距離で各人物に割り当てる．
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
    "pose_landmarker_full.task": MODEL_BASE + "pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task",
    "hand_landmarker.task": MODEL_BASE + "hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task",
    "face_landmarker.task": MODEL_BASE + "face_landmarker/face_landmarker/float16/latest/face_landmarker.task",
}
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
    if not os.path.exists(path):
        print(f"downloading {name}...", file=sys.stderr, flush=True)
        urllib.request.urlretrieve(MODELS[name], path)
    return path


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
    """Pose / Hand / Face Landmarker を組み合わせて複数人を検出する"""

    def __init__(self):
        self.pose = vision.PoseLandmarker.create_from_options(vision.PoseLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=model_path("pose_landmarker_full.task")),
            running_mode=vision.RunningMode.VIDEO, num_poses=MAX_PEOPLE,
        ))
        self.hand = vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=model_path("hand_landmarker.task")),
            running_mode=vision.RunningMode.VIDEO, num_hands=MAX_PEOPLE * 2,
        ))
        self.face = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=model_path("face_landmarker.task")),
            running_mode=vision.RunningMode.VIDEO, num_faces=MAX_PEOPLE,
        ))

    def detect(self, image, ts):
        pr = self.pose.detect_for_video(image, ts)
        hr = self.hand.detect_for_video(image, ts)
        fr = self.face.detect_for_video(image, ts)

        people = []
        for i, pose in enumerate(pr.pose_landmarks):
            p = empty_person()
            p["pose"] = norm(pose, True)
            p["pose_world"] = norm(pr.pose_world_landmarks[i], False) if i < len(pr.pose_world_landmarks) else []
            people.append(p)

        # 手：handedness（本人の左右）ごとに，pose の同じ側の手首（左 15 / 右 16）に最も近い人物へ割り当てる
        for hand, handed in zip(hr.hand_landmarks, hr.handedness):
            label = handed[0].category_name if handed else "Right"
            key, wrist_idx = ("lh", 15) if label == "Left" else ("rh", 16)
            wx, wy = hand[0].x, hand[0].y
            best, best_d = None, 0.15  # 手のひら数個分より離れていれば割り当てない
            for p in people:
                if p[key]:
                    continue
                pw = p["pose"][wrist_idx]
                d = math.hypot(pw[0] - wx, pw[1] - wy)
                if d < best_d:
                    best, best_d = p, d
            if best is not None:
                best[key] = norm(hand, False)

        # 顔：鼻先（face 1）と pose の鼻（0）が最も近い人物へ
        for face in fr.face_landmarks:
            nx, ny = face[1].x, face[1].y
            best, best_d = None, 0.15
            for p in people:
                if p["face"]:
                    continue
                pn = p["pose"][0]
                d = math.hypot(pn[0] - nx, pn[1] - ny)
                if d < best_d:
                    best, best_d = p, d
            if best is not None:
                best["face"] = norm(face, False)

        if not people:
            return empty_person(), []
        # 中央の人物：肩の中点（11, 12）の x が 0.5 に最も近い人
        def center_dist(p):
            a, b = p["pose"][11], p["pose"][12]
            return abs((a[0] + b[0]) / 2 - 0.5)
        people.sort(key=center_dist)
        return people[0], people[1:]

    def close(self):
        self.pose.close()
        self.hand.close()
        self.face.close()


def create_detector(mode):
    return MultiDetector() if mode == MODE_MULTI else SingleDetector()


def main() -> None:
    mode = MODE_SINGLE
    detector = create_detector(mode)
    out = sys.stdout
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
