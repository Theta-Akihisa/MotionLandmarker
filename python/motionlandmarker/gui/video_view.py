"""映像表示（縦横比を保って拡大縮小．ミラー表示．文字の重ね表示）."""
from __future__ import annotations

import numpy as np
from PySide6.QtCore import Qt, QRect
from PySide6.QtGui import QImage, QPainter, QColor, QFont
from PySide6.QtWidgets import QWidget

from ..renderer import Palette


class VideoView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._image: QImage | None = None
        self.mirror = False
        self.message: str | None = None
        self.badge_tl: str | None = None
        self.badge_tr: str | None = None
        self.badge_bl: str | None = None
        self.setMinimumHeight(160)
        self.setAutoFillBackground(False)

    def set_bgr(self, bgr: np.ndarray | None):
        if bgr is None:
            self._image = None
        else:
            h, w = bgr.shape[:2]
            # QImage はバッファを参照するためコピーして保持する
            self._image = QImage(bgr.data, w, h, bgr.strides[0], QImage.Format.Format_BGR888).copy()
        self.update()

    def set_qimage(self, img: QImage | None):
        self._image = img
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(int(Palette.sketch_bg[0] * 255), int(Palette.sketch_bg[1] * 255), int(Palette.sketch_bg[2] * 255)))
        if self._image is not None and self.message is None:
            iw, ih = self._image.width(), self._image.height()
            W, H = self.width(), self.height()
            s = min(W / iw, H / ih)
            w, h = int(iw * s), int(ih * s)
            x, y = (W - w) // 2, (H - h) // 2
            p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
            if self.mirror:
                p.save(); p.translate(x + w, y); p.scale(-1, 1)
                p.drawImage(QRect(0, 0, w, h), self._image)
                p.restore()
            else:
                p.drawImage(QRect(x, y, w, h), self._image)
        elif self.message:
            p.setPen(QColor("white"))
            f = QFont(); f.setPointSizeF(f.pointSizeF() * 1.2); p.setFont(f)
            p.drawText(self.rect().adjusted(24, 24, -24, -24), Qt.AlignmentFlag.AlignCenter | Qt.TextFlag.TextWordWrap, self.message)
        for text, align in ((self.badge_tl, Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop),
                            (self.badge_tr, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignTop),
                            (self.badge_bl, Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignBottom)):
            if not text:
                continue
            p.setFont(QFont())
            r = p.fontMetrics().boundingRect(text).adjusted(-8, -4, 8, 4)
            area = self.rect().adjusted(12, 12, -12, -12)
            if align & Qt.AlignmentFlag.AlignRight:
                r.moveRight(area.right())
            else:
                r.moveLeft(area.left())
            if align & Qt.AlignmentFlag.AlignBottom:
                r.moveBottom(area.bottom())
            else:
                r.moveTop(area.top())
            p.setPen(Qt.PenStyle.NoPen); p.setBrush(QColor(0, 0, 0, 128)); p.drawRoundedRect(r, 8, 8)
            p.setPen(QColor("white")); p.drawText(r, Qt.AlignmentFlag.AlignCenter, text)
        p.end()
