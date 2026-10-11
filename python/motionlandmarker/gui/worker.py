"""推論ワーカー（別スレッド）．1 フレームだけ in-flight にし，追いつかない分は捨てる．動画の取り込みもここで行う."""
from __future__ import annotations

import threading
import time
from pathlib import Path

import numpy as np
from PySide6.QtCore import QObject, QThread, Signal, Slot

from ..detectors import MODE_SINGLE
from ..importer import import_video
from ..pipeline import Pipeline


class Worker(QObject):
    result = Signal(object, object, object, int)      # image(bgr|None), Frame, metrics, recorded
    ready = Signal()
    mode_changed = Signal(int)
    failed = Signal(str)
    import_progress = Signal(int, int)
    import_finished = Signal(object, str)              # Recorder | None, error message

    def __init__(self):
        super().__init__()
        self.pipeline = Pipeline(MODE_SINGLE)
        self.busy = threading.Event()
        self.cancel_import = threading.Event()

    @Slot()
    def warm_up(self):
        """モデルを先に読み込む（最初のフレームで待たされないように）."""
        try:
            dummy = np.zeros((360, 640, 3), np.uint8)
            self.pipeline.process(dummy, 0)
            self.pipeline.reset_timing()
            self.ready.emit()
        except Exception as e:
            self.failed.emit(str(e))

    @Slot(object, int)
    def process(self, bgr, ms: int):
        try:
            self.result.emit(*self.pipeline.process(bgr, ms))
        except Exception as e:
            self.failed.emit(str(e))
        finally:
            self.busy.clear()

    @Slot(int)
    def set_mode(self, mode: int):
        self.busy.set()
        try:
            self.pipeline.set_mode(mode)
            dummy = np.zeros((360, 640, 3), np.uint8)
            self.pipeline.process(dummy, 0)
            self.pipeline.reset_timing()
            self.mode_changed.emit(mode)
        except Exception as e:
            self.failed.emit(str(e))
        finally:
            self.busy.clear()

    @Slot(str, str, bool)
    def run_import(self, video: str, output_root: str, multi: bool):
        self.busy.set()
        self.cancel_import.clear()
        try:
            r = import_video(Path(video), Path(output_root), self.pipeline, multi,
                             progress=lambda d, t: self.import_progress.emit(d, t),
                             is_cancelled=self.cancel_import.is_set,
                             on_frame=lambda img, fr, m, rec: self.result.emit(img, fr, m, rec))
            self.import_finished.emit(r, "")
        except Exception as e:
            self.import_finished.emit(None, str(e))
        finally:
            self.busy.clear()

    @Slot()
    def shutdown(self):
        self.pipeline.close()


class WorkerThread:
    """Worker を別スレッドで動かすための入れ物."""

    def __init__(self):
        self.thread = QThread()
        self.worker = Worker()
        self.worker.moveToThread(self.thread)
        self.thread.start()

    def stop(self):
        self.worker.shutdown()
        self.thread.quit()
        self.thread.wait(3000)
