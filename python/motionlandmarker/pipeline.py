"""検出 → 指標 → 描画 → 録画 の流れ（GUI に依存しない）．Swift 版 LandmarkPipeline の移植."""
from __future__ import annotations

import threading
import time
from pathlib import Path

import cv2
import numpy as np

from .detectors import Detector, MODE_SINGLE
from .landmarks import Frame
from .recorder import Recorder
from . import metrics as M
from . import renderer

INFERENCE_WIDTH = 640


class Pipeline:
    """1 フレームずつ同期的に処理する．スレッド安全（lock）."""

    def __init__(self, mode: int = MODE_SINGLE):
        self.detector = Detector(mode)
        self.lock = threading.Lock()
        self.recorder: Recorder | None = None
        self.previous: Frame | None = None
        self.draw_options = renderer.DrawOptions()
        self.live_style = "overlay"   # raw | skeleton | overlay | hidden
        self.frame_size = (1280, 720)
        self.fps_hint = 30.0

    def set_mode(self, mode: int):
        with self.lock:
            self.detector.set_mode(mode)
            self.previous = None

    def reset_timing(self):
        with self.lock:
            self.previous = None

    def process(self, bgr: np.ndarray, timestamp_ms: int):
        """フレーム（BGR）を処理し，(表示用 BGR | None, Frame, metrics, 録画フレーム数) を返す."""
        if bgr is None or bgr.ndim != 3 or bgr.shape[0] < 2 or bgr.shape[1] < 2:
            raise ValueError(f"invalid frame: {None if bgr is None else bgr.shape}")
        h, w = bgr.shape[:2]
        iw = INFERENCE_WIDTH
        ih = max(1, int(round(h * iw / w)))
        small = cv2.resize(bgr, (iw, ih), interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
        with self.lock:
            frame = self.detector.detect(rgb, timestamp_ms)
            frame.timestamp_ms = timestamp_ms   # 単調補正された値ではなく元の時刻を記録する
            self.frame_size = (w, h)
            metrics = M.compute(frame, self.previous)
            self.previous = frame
            style = self.live_style
            if style == "hidden":
                image = None
            elif style == "raw":
                image = bgr
            elif style == "skeleton":
                image = renderer.compose(frame, None, (w, h), self.draw_options)
            else:
                image = renderer.compose(frame, bgr, (w, h), self.draw_options)
            if self.recorder is not None:
                self.recorder.append(frame, bgr, metrics)
            recorded = self.recorder.frame_count if self.recorder else 0
        return image, frame, metrics, recorded

    def start_recording(self, output_root: Path, stem: str, multi_person: bool = False):
        with self.lock:
            self.recorder = Recorder(output_root, stem, self.frame_size, self.fps_hint, multi_person)

    def stop_recording(self) -> Recorder | None:
        with self.lock:
            r, self.recorder = self.recorder, None
        if r is not None:
            r.finish()
        return r

    def close(self):
        self.stop_recording()
        with self.lock:
            self.detector.close()
