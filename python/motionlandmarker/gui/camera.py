"""Qt Multimedia によるカメラ取り込み（macOS / Windows でデバイス名が取れる）．フレームを BGR の numpy で配る."""
from __future__ import annotations

import time

import numpy as np
from PySide6.QtCore import QObject, Signal, Slot
from PySide6.QtGui import QImage
from PySide6.QtMultimedia import (QCamera, QCameraDevice, QMediaCaptureSession, QMediaDevices,
                                  QVideoFrame, QVideoSink)


def qimage_to_bgr(img: QImage) -> np.ndarray | None:
    """QImage → BGR の numpy．変換できない形式（Windows の一部のカメラ）では RGB32 経由で変換する．失敗時は None."""
    conv = img.convertToFormat(QImage.Format.Format_BGR888)
    if conv.isNull() or conv.width() == 0 or conv.height() == 0:
        conv = img.convertToFormat(QImage.Format.Format_RGB32)   # BGRA（リトルエンディアン）
        if conv.isNull() or conv.width() == 0 or conv.height() == 0:
            return None
        w, h, bpl = conv.width(), conv.height(), conv.bytesPerLine()
        buf = np.frombuffer(conv.constBits(), np.uint8, count=bpl * h).reshape(h, bpl)[:, : w * 4]
        # QImage のバッファは conv の寿命とともに解放されるため，必ずコピーして返す
        # （ascontiguousarray は既に連続なら参照を返すので使わない）
        return buf.reshape(h, w, 4)[:, :, :3].copy()
    w, h, bpl = conv.width(), conv.height(), conv.bytesPerLine()
    buf = np.frombuffer(conv.constBits(), np.uint8, count=bpl * h).reshape(h, bpl)[:, : w * 3]
    return buf.reshape(h, w, 3).copy()


class Camera(QObject):
    """frame(bgr, timestamp_ms) を出す．timestamp はセッション開始からの経過ミリ秒."""
    frame = Signal(object, int)
    devices_changed = Signal()
    error = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.session = QMediaCaptureSession(self)
        self.sink = QVideoSink(self)
        self.session.setVideoSink(self.sink)
        self.sink.videoFrameChanged.connect(self._on_frame)
        self.camera: QCamera | None = None
        self._start = None
        self._media_devices = QMediaDevices(self)
        self._media_devices.videoInputsChanged.connect(self.devices_changed)

    @staticmethod
    def devices() -> list[QCameraDevice]:
        return list(QMediaDevices.videoInputs())

    def select(self, device: QCameraDevice):
        if self.camera is not None:
            self.camera.stop()
            self.camera.deleteLater()
        self.camera = QCamera(device, self)
        # 横長で 1280x720 以下のうち最大のフォーマットを選ぶ（縦長や 4K は避ける）
        best = None
        for f in device.videoFormats():
            r = f.resolution()
            if r.width() < r.height() or r.width() > 1280:
                continue
            if best is None or r.width() * r.height() > best.resolution().width() * best.resolution().height():
                best = f
        if best is not None:
            self.camera.setCameraFormat(best)
        self.camera.errorOccurred.connect(lambda e, s: self.error.emit(f"{s} ({e})"))
        if self.camera.error() != QCamera.Error.NoError:
            self.error.emit(self.camera.errorString())
        self.session.setCamera(self.camera)
        self.camera.start()

    def stop(self):
        if self.camera is not None:
            self.camera.stop()

    def resume(self):
        if self.camera is not None and not self.camera.isActive():
            self.camera.start()

    @property
    def is_running(self) -> bool:
        return self.camera is not None and self.camera.isActive()

    @Slot(QVideoFrame)
    def _on_frame(self, vf: QVideoFrame):
        if not vf.isValid():
            return
        img = vf.toImage()
        if img.isNull():
            return
        bgr = qimage_to_bgr(img)
        if bgr is None or bgr.size == 0:
            return
        # フレームの回転・反転情報（toImage では適用されない）を反映する
        try:
            r = vf.rotation()                  # Qt 6.7+（QtVideo.Rotation）
        except AttributeError:
            r = vf.surfaceFormat().rotation()
        rot = int(getattr(r, "value", r))
        if rot == 90:
            bgr = np.rot90(bgr, -1).copy()
        elif rot == 180:
            bgr = np.rot90(bgr, 2).copy()
        elif rot == 270:
            bgr = np.rot90(bgr, 1).copy()
        if vf.mirrored() if hasattr(vf, "mirrored") else vf.surfaceFormat().isMirrored():
            bgr = bgr[:, ::-1].copy()
        now = time.monotonic()
        if self._start is None:
            self._start = now
        ms = int((now - self._start) * 1000)
        self.frame.emit(bgr, ms)
