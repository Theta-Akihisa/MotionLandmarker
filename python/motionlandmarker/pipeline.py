"""検出 → 指標 → 描画 → 録画 の流れ（GUI に依存しない）．Swift 版 LandmarkPipeline の移植."""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

from .detectors import Detector, MODE_SINGLE
from .landmarks import Frame
from .recorder import Recorder
from . import metrics as M
from . import renderer

INFERENCE_WIDTH = 640


@dataclass
class Processed:
    """1 フレームの処理結果."""
    image: np.ndarray | None                     # 表示用の全体映像（BGR．非表示なら None）
    frame: Frame
    metrics: dict[str, float]                    # 中央の人物（1 人モードでは検出した 1 人）の指標
    recorded: int                                # 録画済みフレーム数
    tiles: list[renderer.Tile] = field(default_factory=list)            # 複数人モードの人物ごとの Box（番号順）
    slot_metrics: dict[int, dict[str, float]] = field(default_factory=dict)   # 人物番号 -> 指標（複数人モード）


class Pipeline:
    """1 フレームずつ同期的に処理する．スレッド安全（lock）."""

    def __init__(self, mode: int = MODE_SINGLE):
        self.detector = Detector(mode)
        self.lock = threading.Lock()
        self.recorder: Recorder | None = None
        self.previous: Frame | None = None
        self.previous_by_slot: dict[int, Frame] = {}
        self.tile_aspects: dict[int, float] = {}     # タイル数 -> 表示のマスの縦横比（GUI が設定する．無ければ既定値）
        self.draw_options = renderer.DrawOptions()
        self.live_style = "overlay"   # raw | skeleton | overlay | hidden
        self.frame_size = (1280, 720)
        self.fps_hint = 30.0

    def set_mode(self, mode: int):
        with self.lock:
            self.detector.set_mode(mode)
            self.previous = None
            self.previous_by_slot = {}

    def reset_timing(self):
        with self.lock:
            self.previous = None
            self.previous_by_slot = {}

    def reset_tracking(self):
        """人物の追跡と人物番号を最初からやり直す（動画の処理の前後．番号が 1 から振られるように）."""
        with self.lock:
            self.detector.close()
            self.previous = None
            self.previous_by_slot = {}

    def process(self, bgr: np.ndarray, timestamp_ms: int):
        """フレーム（BGR）を処理して Processed を返す."""
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
            # 人物番号ごとの指標（速度は同じ番号の前フレームとの差．前フレームにいなければ出ない）
            slot_metrics, by_slot = {}, {}
            for p in frame.numbered_people():
                f = Frame(timestamp_ms=timestamp_ms, person=p)
                slot_metrics[p.slot] = M.compute(f, self.previous_by_slot.get(p.slot))
                by_slot[p.slot] = f
            self.previous_by_slot = by_slot
            style = self.live_style
            if style == "hidden":
                image = None
            elif style == "raw":
                image = bgr
            elif style == "skeleton":
                image = renderer.compose(frame, None, (w, h), self.draw_options)
            else:
                image = renderer.compose(frame, bgr, (w, h), self.draw_options)
            tiles = []
            if style != "hidden":
                people = frame.numbered_people()
                count = 1 + max((q.slot for q in people), default=0)
                aspect = self.tile_aspects.get(count, renderer.TILE_ASPECT)
                tiles = renderer.person_tiles(people, bgr, (w, h), style, self.draw_options, aspect)
            if self.recorder is not None:
                self.recorder.append(frame, bgr, metrics)
            recorded = self.recorder.frame_count if self.recorder else 0
        return Processed(image, frame, metrics, recorded, tiles, slot_metrics)

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
