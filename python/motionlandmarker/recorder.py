"""録画の書き出し（Swift 版 LandmarkRecorder.swift / video2landmark の save2csv.py, save2json.py と同じ形式）．

results_data/
  csv/{stem}/{stem}_{face,hand,pose,metrics}.csv
  json/{stem}/{stem}_{face,hand,pose}.json（複数人モードは {stem}_people.json も）
  video_raw / video_overlay / video_skeleton/{stem}_xxx.mp4
"""
from __future__ import annotations

import contextlib
import csv
import json
import os
import sys
from pathlib import Path

import cv2
import numpy as np

from .landmarks import Frame, Person, POSE_COUNT, FACE_COUNT, HAND_COUNT
from .metrics import KINDS
from . import renderer


@contextlib.contextmanager
def _suppress_stderr():
    """コーデック探索中にネイティブ層が stderr へ書くエラーを抑える."""
    sys.stderr.flush()
    try:
        saved = os.dup(2)
        devnull = os.open(os.devnull, os.O_WRONLY)
    except OSError:
        yield
        return
    try:
        os.dup2(devnull, 2)
        yield
    finally:
        sys.stderr.flush()
        os.dup2(saved, 2)
        os.close(devnull)
        os.close(saved)


def open_writer(path: Path, fps: float, size: tuple[int, int]) -> cv2.VideoWriter:
    """H.264 (avc1) を試し，使えなければ mp4v にフォールバックする（Windows では通常 mp4v）."""
    for codec in ("avc1", "mp4v"):
        with _suppress_stderr():
            w = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*codec), fps, size)
            ok = w.isOpened()
        if ok:
            return w
        w.release()
    raise RuntimeError(f"Cannot open VideoWriter for {path}")


def _xyz_cols(a: np.ndarray, count: int) -> list[str]:
    if len(a) != count:
        return [""] * (count * 3)
    return [repr(float(v)) for row in a for v in row[:3]]


def _xyz_json(a: np.ndarray, count: int):
    if len(a) != count:
        return None
    return [{"x": float(r[0]), "y": float(r[1]), "z": float(r[2])} for r in a]


def _pose_json(a: np.ndarray):
    if len(a) != POSE_COUNT:
        return None
    return [{"x": float(r[0]), "y": float(r[1]), "z": float(r[2]), "visibility": float(r[3])} for r in a]


class Recorder:
    def __init__(self, output_root: Path, stem: str, size: tuple[int, int], fps: float = 30.0,
                 multi_person: bool = False):
        self.stem = stem
        self.size = size
        self.multi_person = multi_person
        self.frame_count = 0
        self.skipped_video_frames = 0
        root = Path(output_root)
        self.csv_dir = root / "csv" / stem
        self.json_dir = root / "json" / stem
        for d in (self.csv_dir, self.json_dir, root / "video_raw", root / "video_overlay", root / "video_skeleton"):
            d.mkdir(parents=True, exist_ok=True)
        self.raw_url = root / "video_raw" / f"{stem}_raw.mp4"
        self.overlay_url = root / "video_overlay" / f"{stem}_overlay.mp4"
        self.skeleton_url = root / "video_skeleton" / f"{stem}_skeleton.mp4"
        # 動画はフレーム間隔が一定でないため，公称 fps で書く（時刻は CSV の timestamp_ms が正）
        self._raw = open_writer(self.raw_url, fps, size)
        self._overlay = open_writer(self.overlay_url, fps, size)
        self._skeleton = open_writer(self.skeleton_url, fps, size)

        self._face_f = open(self.csv_dir / f"{stem}_face.csv", "w", newline="", encoding="utf-8")
        self._hand_f = open(self.csv_dir / f"{stem}_hand.csv", "w", newline="", encoding="utf-8")
        self._pose_f = open(self.csv_dir / f"{stem}_pose.csv", "w", newline="", encoding="utf-8")
        self._metrics_f = open(self.csv_dir / f"{stem}_metrics.csv", "w", newline="", encoding="utf-8")
        self._face_w = csv.writer(self._face_f, lineterminator="\n")
        self._hand_w = csv.writer(self._hand_f, lineterminator="\n")
        self._pose_w = csv.writer(self._pose_f, lineterminator="\n")
        self._metrics_w = csv.writer(self._metrics_f, lineterminator="\n")
        self._face_w.writerow(["frame", "timestamp_ms"] + [f"lm_{i}_{c}" for i in range(FACE_COUNT) for c in "xyz"])
        self._hand_w.writerow(["frame", "timestamp_ms"]
                              + [f"{s}_{i}_{c}" for s in ("left", "right") for i in range(HAND_COUNT) for c in "xyz"])
        self._pose_w.writerow(["frame", "timestamp_ms"]
                              + [f"lm_{i}_{c}" for i in range(POSE_COUNT) for c in ("x", "y", "z", "visibility")])
        self._metrics_w.writerow(["frame", "timestamp_ms"] + KINDS)
        self._json_face: list = []
        self._json_hand: list = []
        self._json_pose: list = []
        self._json_people: list = []

    def append(self, frame: Frame, background: np.ndarray | None, metrics: dict[str, float]):
        p = frame.person
        i, ts = self.frame_count, frame.timestamp_ms
        for writer, img in ((self._raw, renderer.compose(None, background, self.size)),
                            (self._overlay, renderer.compose(frame, background, self.size)),
                            (self._skeleton, renderer.compose(frame, None, self.size))):
            if img.shape[1] != self.size[0] or img.shape[0] != self.size[1]:
                img = cv2.resize(img, self.size)
            writer.write(img)
        self._face_w.writerow([i, ts] + _xyz_cols(p.face, FACE_COUNT))
        self._hand_w.writerow([i, ts] + _xyz_cols(p.left_hand, HAND_COUNT) + _xyz_cols(p.right_hand, HAND_COUNT))
        if p.has_pose:
            self._pose_w.writerow([i, ts] + [repr(float(v)) for row in p.pose for v in row])
        else:
            self._pose_w.writerow([i, ts] + [""] * (POSE_COUNT * 4))
        self._metrics_w.writerow([i, ts] + [repr(float(metrics[k])) if k in metrics else "" for k in KINDS])
        self._json_face.append({"frame": i, "timestamp_ms": ts, "landmarks": _xyz_json(p.face, FACE_COUNT)})
        self._json_hand.append({"frame": i, "timestamp_ms": ts,
                                "left": _xyz_json(p.left_hand, HAND_COUNT), "right": _xyz_json(p.right_hand, HAND_COUNT)})
        self._json_pose.append({"frame": i, "timestamp_ms": ts, "landmarks": _pose_json(p.pose)})
        if self.multi_person:
            people = ([p] if p.has_pose else []) + list(frame.others)
            self._json_people.append({"frame": i, "timestamp_ms": ts, "people": [
                {"pose": _pose_json(q.pose), "face": _xyz_json(q.face, FACE_COUNT),
                 "left": _xyz_json(q.left_hand, HAND_COUNT), "right": _xyz_json(q.right_hand, HAND_COUNT)}
                for q in people]})
        self.frame_count += 1

    def finish(self):
        for w in (self._raw, self._overlay, self._skeleton):
            w.release()
        for f in (self._face_f, self._hand_f, self._pose_f, self._metrics_f):
            f.close()
        for name, data in (("face", self._json_face), ("hand", self._json_hand), ("pose", self._json_pose)):
            with open(self.json_dir / f"{self.stem}_{name}.json", "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
        if self.multi_person:
            with open(self.json_dir / f"{self.stem}_people.json", "w", encoding="utf-8") as f:
                json.dump(self._json_people, f, indent=2)

    @property
    def output_paths(self) -> list[Path]:
        return [self.csv_dir, self.json_dir, self.raw_url, self.overlay_url, self.skeleton_url]
