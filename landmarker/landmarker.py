"""MediaPipe Holistic landmark sidecar.

Protocol (binary stdin / text stdout):
  stdin  : [uint32 BE payload_len][uint64 BE timestamp_ms][JPEG bytes]
  stdout : one JSON object per line
           {"t": timestamp_ms, "pose": [[x,y,z,vis]*33] | [],
            "pose_world": [[x,y,z]*33] | [],   # メートル単位のワールド座標（体の向きの計算用）
            "face": [[x,y,z]*478] | [], "lh": [[x,y,z]*21] | [], "rh": [[x,y,z]*21] | []}
  A line {"ready": true} is emitted once the model is loaded.
"""
import json
import os
import struct
import sys
import urllib.request

import cv2
import numpy as np
import mediapipe as mp
from mediapipe.tasks.python import BaseOptions, vision

MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/holistic_landmarker/"
             "holistic_landmarker/float16/latest/holistic_landmarker.task")


def model_path() -> str:
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", "holistic_landmarker.task")
    if os.path.exists(here):
        return here
    support = os.path.expanduser("~/Library/Application Support/MotionLandmarker/models")
    os.makedirs(support, exist_ok=True)
    path = os.path.join(support, "holistic_landmarker.task")
    if not os.path.exists(path):
        print("downloading model...", file=sys.stderr, flush=True)
        urllib.request.urlretrieve(MODEL_URL, path)
    return path


def norm(lms, with_vis: bool):
    if with_vis:
        return [[l.x, l.y, l.z, l.visibility or 0.0] for l in lms]
    return [[l.x, l.y, l.z] for l in lms]


def main() -> None:
    options = vision.HolisticLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=model_path()),
        running_mode=vision.RunningMode.VIDEO,
    )
    landmarker = vision.HolisticLandmarker.create_from_options(options)
    out = sys.stdout
    stdin = sys.stdin.buffer
    out.write(json.dumps({"ready": True}) + "\n")
    out.flush()

    last_ts = -1
    while True:
        header = stdin.read(12)
        if len(header) < 12:
            break
        length, ts = struct.unpack(">IQ", header)
        payload = stdin.read(length)
        if len(payload) < length:
            break
        ts = max(int(ts), last_ts + 1)  # VIDEO mode requires monotonic timestamps
        last_ts = ts
        bgr = cv2.imdecode(np.frombuffer(payload, np.uint8), cv2.IMREAD_COLOR)
        if bgr is None:
            continue
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        r = landmarker.detect_for_video(image, ts)
        out.write(json.dumps({
            "t": ts,
            "pose": norm(r.pose_landmarks, True),
            "pose_world": norm(r.pose_world_landmarks, False),
            "face": norm(r.face_landmarks, False),
            "lh": norm(r.left_hand_landmarks, False),
            "rh": norm(r.right_hand_landmarks, False),
        }, separators=(",", ":")) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
