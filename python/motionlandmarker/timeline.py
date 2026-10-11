"""録画の再生時に波形を出すための指標の時系列（Swift 版 PlaybackTimeline.swift の移植）."""
from __future__ import annotations

import csv
from pathlib import Path

import numpy as np

from .landmarks import Frame, Person, POSE_COUNT, FACE_COUNT, HAND_COUNT
from . import metrics as M

VARIANT_SUFFIXES = ("_overlay", "_raw", "_skeleton")


def recording_parts(video: Path) -> tuple[str, Path, str] | None:
    """動画 URL から (stem, 出力ルート, 種類) を取り出す．録画の配置でなければ None."""
    name = video.stem
    for suf in VARIANT_SUFFIXES:
        if name.endswith(suf):
            return name[: -len(suf)], video.parent.parent, suf[1:]
    return None


def variant_path(root: Path, stem: str, variant: str) -> Path:
    return root / f"video_{variant}" / f"{stem}_{variant}.mp4"


class Timeline:
    def __init__(self, timestamps: np.ndarray, values: dict[str, np.ndarray]):
        self.timestamps = timestamps          # ms（int64）
        self.values = values                  # kind -> float32（NaN = 未検出）

    def __len__(self):
        return len(self.timestamps)

    @property
    def first_timestamp(self) -> int:
        return int(self.timestamps[0]) if len(self.timestamps) else 0

    @property
    def seconds(self) -> np.ndarray:
        """動画の先頭を 0 とした秒."""
        return (self.timestamps - self.first_timestamp) / 1000.0

    @classmethod
    def load_for_video(cls, video: Path) -> "Timeline | None":
        parts = recording_parts(video)
        if parts is None:
            return None
        stem, root, _ = parts
        csv_dir = root / "csv" / stem
        t = cls.load_metrics_csv(csv_dir / f"{stem}_metrics.csv")
        if t is not None:
            return t
        return cls.compute_from_landmark_csv(csv_dir, stem)

    @classmethod
    def load_metrics_csv(cls, path: Path) -> "Timeline | None":
        if not path.exists():
            return None
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.reader(f)
            header = next(reader, None)
            if not header or header[:2] != ["frame", "timestamp_ms"]:
                return None
            kinds = header[2:]
            ts, cols = [], {k: [] for k in kinds}
            for row in reader:
                if len(row) != len(header):
                    continue
                ts.append(int(row[1]))
                for k, v in zip(kinds, row[2:]):
                    cols[k].append(float(v) if v else np.nan)
        values = {k: np.array(cols.get(k, []), np.float32) if k in cols else np.full(len(ts), np.nan, np.float32)
                  for k in M.KINDS}
        return cls(np.array(ts, np.int64), values)

    @classmethod
    def compute_from_landmark_csv(cls, csv_dir: Path, stem: str) -> "Timeline | None":
        """metrics CSV が無い録画向け．ワールド座標は無いため体のヨーは出ない."""
        def rows(name):
            p = csv_dir / f"{stem}_{name}.csv"
            if not p.exists():
                return None
            with open(p, newline="", encoding="utf-8") as f:
                r = csv.reader(f); next(r, None)
                return list(r)
        pose, face, hand = rows("pose"), rows("face"), rows("hand")
        if pose is None or face is None or hand is None:
            return None
        n = min(len(pose), len(face), len(hand))

        def pts(cols, start, count, stride):
            out = np.zeros((count, stride), np.float64)
            for i in range(count):
                b = start + i * stride
                try:
                    out[i] = [float(cols[b + j]) for j in range(stride)]
                except (ValueError, IndexError):
                    return np.zeros((0, stride), np.float64)
            return out

        ts, vals = [], {k: [] for k in M.KINDS}
        prev = None
        for i in range(n):
            t = int(pose[i][1])
            p = Person(pose=pts(pose[i], 2, POSE_COUNT, 4), face=pts(face[i], 2, FACE_COUNT, 3),
                       left_hand=pts(hand[i], 2, HAND_COUNT, 3), right_hand=pts(hand[i], 2 + HAND_COUNT * 3, HAND_COUNT, 3))
            fr = Frame(timestamp_ms=t, person=p)
            m = M.compute(fr, prev)
            prev = fr
            ts.append(t)
            for k in M.KINDS:
                vals[k].append(m.get(k, np.nan))
        return cls(np.array(ts, np.int64), {k: np.array(v, np.float32) for k, v in vals.items()})
