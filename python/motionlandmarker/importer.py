"""動画ファイルを読み込み，カメラと同じパイプラインで全フレームを処理して書き出す."""
from __future__ import annotations

from pathlib import Path
from typing import Callable

import cv2

from .pipeline import Pipeline
from .recorder import Recorder


def import_video(video: Path, output_root: Path, pipeline: Pipeline, multi_person: bool = False,
                 progress: Callable[[int, int], None] | None = None,
                 is_cancelled: Callable[[], bool] | None = None,
                 on_frame: Callable | None = None) -> Recorder:
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise RuntimeError(f"動画を開けません: {video}")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    pipeline.fps_hint = fps
    pipeline.reset_timing()
    stem = Path(video).stem
    sent = 0
    recorder_started = False
    try:
        while True:
            if is_cancelled is not None and is_cancelled():
                break
            ok, frame = cap.read()
            if not ok:
                break
            pos = cap.get(cv2.CAP_PROP_POS_MSEC)
            ts = int(round(pos)) if pos and pos > 0 else int(sent * 1000.0 / fps)
            result = pipeline.process(frame, ts)
            sent += 1
            if on_frame is not None:
                on_frame(*result)
            if not recorder_started:
                # 録画サイズは最初のフレームから決まる（カメラと同じ流れ）．先頭フレームは記録に含めない
                pipeline.start_recording(output_root, stem, multi_person)
                recorder_started = True
            if progress is not None:
                progress(sent, max(total, sent))
    finally:
        cap.release()
    if sent == 0:
        raise RuntimeError("動画からフレームを読み出せません")
    r = pipeline.stop_recording()
    assert r is not None
    return r
