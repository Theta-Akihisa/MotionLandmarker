"""映像表示（縦横比を保って拡大縮小．ミラー表示．文字の重ね表示．複数人モードのタイル表示）."""
from __future__ import annotations

import numpy as np
from PySide6.QtCore import Qt, QRect, QRectF, Signal
from PySide6.QtGui import QImage, QPainter, QColor, QFont, QPen
from PySide6.QtWidgets import QWidget

from ..renderer import Palette, Tile

TILE_GAP = 4


def tile_grid(count: int) -> tuple[int, int, list[tuple[int, int]]]:
    """タイル数（全体映像 1 ＋ 見えている人物番号の最大値）から (行数, 列数, 各タイルの (行, 列)) を返す．

    4 タイル以下（3 人以下）は横 1 列（左から 全体映像，1人目，2人目，3人目）．
    5〜6 タイル（4〜5 人）は 2×3（左上が全体映像，以降は左から右・上から下．5 人目は右下）．
    """
    count = max(1, count)
    rows, cols = (1, count) if count <= 4 else (2, 3)
    return rows, cols, [divmod(i, cols) for i in range(count)]


def _bgr_to_qimage(bgr: np.ndarray) -> QImage:
    h, w = bgr.shape[:2]
    # QImage はバッファを参照するためコピーして保持する
    return QImage(bgr.data, w, h, bgr.strides[0], QImage.Format.Format_BGR888).copy()


def _qcolor(rgb) -> QColor:
    return QColor(int(rgb[0] * 255), int(rgb[1] * 255), int(rgb[2] * 255))


class VideoView(QWidget):
    resized = Signal()      # 大きさが変わった（人物タイルの縦横比を合わせ直すため）

    def __init__(self, parent=None):
        super().__init__(parent)
        self._image: QImage | None = None
        self._tiles: list[tuple[int, tuple[float, float, float, float], QImage]] = []   # (人物番号, bbox, 画像)
        self.mirror = False
        self.message: str | None = None
        self.badge_tl: str | None = None
        self.badge_tr: str | None = None
        self.badge_bl: str | None = None
        self.setMinimumHeight(160)
        self.setAutoFillBackground(False)

    def set_bgr(self, bgr: np.ndarray | None):
        """全体映像だけを表示する（タイルは消す）."""
        self.set_tiles(bgr, [])

    def set_tiles(self, bgr: np.ndarray | None, tiles: list[Tile]):
        """全体映像（BGR）と人物ごとの Box を表示する．tiles が空なら全体映像のみ（従来の表示）."""
        self._image = None if bgr is None else _bgr_to_qimage(bgr)
        self._tiles = [(t.slot, t.bbox, _bgr_to_qimage(t.image)) for t in tiles] if bgr is not None else []
        self.update()

    def set_qimage(self, img: QImage | None):
        self._image = img
        self._tiles = []
        self.update()

    @property
    def tile_slots(self) -> list[int]:
        """人物タイルに割り当てる番号（1〜見えている番号の最大値）．いない番号も空きの枠として残す
        （1人目と3人目だけ見えていれば 1, 2, 3 で，2 は空き）．人物がいなければ空."""
        top = max((slot for slot, _, _ in self._tiles), default=0)
        return list(range(1, top + 1))

    @property
    def tile_count(self) -> int:
        return 0 if self._image is None else 1 + len(self.tile_slots)

    def _cell_size(self, count: int) -> tuple[int, int, int, int, list[tuple[int, int]]]:
        rows, cols, cells = tile_grid(count)
        W, H = self.width(), self.height()
        return (W - TILE_GAP * (cols - 1)) / cols, (H - TILE_GAP * (rows - 1)) / rows, rows, cols, cells

    def tile_rects(self) -> list[QRect]:
        """各タイルの表示枠（ウィジェット座標）．並べ方は tile_grid に従う."""
        cw, ch, _, _, cells = self._cell_size(self.tile_count)
        return [QRect(int(c * (cw + TILE_GAP)), int(r * (ch + TILE_GAP)), int(cw), int(ch)) for r, c in cells]

    def tile_aspects(self) -> dict[int, float]:
        """タイル数（2〜6）ごとのマスの縦横比（幅 / 高さ）．人物タイルの切り出しをこれに合わせる."""
        out = {}
        for count in range(2, 7):
            cw, ch, *_ = self._cell_size(count)
            out[count] = max(0.2, min(5.0, cw / ch)) if cw > 0 and ch > 0 else 0.75
        return out

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.resized.emit()

    def _draw_fit(self, p: QPainter, img: QImage, area: QRect) -> QRect:
        """area に縦横比を保って img を描き，実際に描いた範囲を返す（ミラー時は左右反転）."""
        iw, ih = img.width(), img.height()
        s = min(area.width() / iw, area.height() / ih)
        w, h = int(iw * s), int(ih * s)
        x, y = area.x() + (area.width() - w) // 2, area.y() + (area.height() - h) // 2
        if self.mirror:
            p.save(); p.translate(x + w, y); p.scale(-1, 1)
            p.drawImage(QRect(0, 0, w, h), img)
            p.restore()
        else:
            p.drawImage(QRect(x, y, w, h), img)
        return QRect(x, y, w, h)

    def _draw_label(self, p: QPainter, text: str, color: QColor, x: float, y: float):
        p.setFont(QFont())
        r = p.fontMetrics().boundingRect(text).adjusted(-6, -2, 6, 2)
        r.moveTopLeft(QRect(int(x), int(y), 0, 0).topLeft())
        p.setPen(Qt.PenStyle.NoPen); p.setBrush(color); p.drawRoundedRect(r, 4, 4)
        p.setPen(QColor("black")); p.drawText(r, Qt.AlignmentFlag.AlignCenter, text)

    def _paint_tiles(self, p: QPainter):
        """複数人モード：全体映像（各人の枠と番号つき）＋人物ごとの Box."""
        rects = self.tile_rects()
        full = self._draw_fit(p, self._image, rects[0])
        for slot, (bx, by, bw, bh), _ in self._tiles:
            col = _qcolor(Palette.for_slot(slot))
            if self.mirror:
                bx = 1.0 - bx - bw
            box = QRectF(full.x() + bx * full.width(), full.y() + by * full.height(), bw * full.width(), bh * full.height())
            p.setPen(QPen(col, 2)); p.setBrush(Qt.BrushStyle.NoBrush); p.drawRect(box)
            self._draw_label(p, str(slot), col, box.x(), box.y())
        # 人物タイルの枠はマス目そのもの（大きさ固定）．人物の Box の縦横比が変わっても枠は動かず，中の映像だけが枠内で拡大縮小する
        images = {slot: img for slot, _, img in self._tiles}
        for slot, area in zip(self.tile_slots, rects[1:]):
            col = _qcolor(Palette.for_slot(slot))
            p.fillRect(area, QColor(0, 0, 0, 90))
            img = images.get(slot)
            if img is not None:
                self._draw_fit(p, img, area)
            else:
                # 空きの枠：暗い背景に「未検出」と出す
                p.setPen(QColor(160, 160, 160)); p.setFont(QFont())
                p.drawText(area, Qt.AlignmentFlag.AlignCenter, "未検出")
            p.setPen(QPen(col, 2)); p.setBrush(Qt.BrushStyle.NoBrush); p.drawRect(area.adjusted(1, 1, -1, -1))
            self._draw_label(p, f"{slot}人目", col, area.x() + 4, area.y() + 4)

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(int(Palette.sketch_bg[0] * 255), int(Palette.sketch_bg[1] * 255), int(Palette.sketch_bg[2] * 255)))
        if self._image is not None and self.message is None:
            p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
            if self._tiles:
                self._paint_tiles(p)
            else:
                self._draw_fit(p, self._image, self.rect())
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
