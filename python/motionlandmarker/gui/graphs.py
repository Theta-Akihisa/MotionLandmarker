"""波形グラフ（pyqtgraph）．Swift 版のグラフ表示の移植．

- 縦軸は項目ごとに固定．横軸はライブでは「現在の過去 10 秒」，再生では録画全体（ホイールでズーム，ドラッグで移動）
- 未検出は NaN で線を途切れさせる．描画点数は系列あたり最大 240 に間引く（通算番号で位相を固定）
- 現在位置 / 再生位置は赤い縦線
"""
from __future__ import annotations

import numpy as np
import pyqtgraph as pg
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont
from PySide6.QtWidgets import QHBoxLayout, QLabel, QVBoxLayout, QWidget, QSizePolicy

from .. import metrics as M
from ..renderer import Palette

pg.setConfigOptions(antialias=False, background=None, foreground="k")

MAX_POINTS = 240


def _qcolor(rgb) -> QColor:
    return QColor(int(rgb[0] * 255), int(rgb[1] * 255), int(rgb[2] * 255))


class ChartWidget(QWidget):
    """1 枚のグラフ（見出し＋凡例＋プロット）."""

    def __init__(self, chart: M.Chart, parent=None):
        super().__init__(parent)
        self.chart = chart
        self.visible_kinds = set(chart.kinds)
        self.title_label = QLabel(chart.title)
        f = self.title_label.font(); f.setBold(True); f.setPointSizeF(f.pointSizeF() * 1.3)
        self.title_label.setFont(f)
        head = QHBoxLayout()
        head.setContentsMargins(0, 0, 0, 0)
        head.setSpacing(30)
        head.addWidget(self.title_label)
        head.addStretch(1)
        self.legend_values: dict[str, QLabel] = {}
        self.legend_items: dict[str, QWidget] = {}
        for k in chart.kinds:
            item = QWidget()
            hl = QHBoxLayout(item); hl.setContentsMargins(0, 0, 0, 0); hl.setSpacing(2)
            dot = QLabel("●"); dot.setStyleSheet(f"color: {_qcolor(Palette.for_kind(k)).name()}")
            name = QLabel(M.LABELS[k]); name.setMinimumWidth(96)
            val = QLabel("--"); val.setMinimumWidth(68); val.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            val.setStyleSheet("color: gray")
            for wdg in (dot, name, val):
                hl.addWidget(wdg)
            hl.addSpacing(3)
            head.addWidget(item)
            self.legend_values[k] = val
            self.legend_items[k] = item

        self.plot = pg.PlotWidget()
        self.plot.setMinimumHeight(120)
        self.plot.setMaximumHeight(140)
        self.plot.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        lo, hi = chart.y_range
        self.plot.setYRange(lo, hi, padding=0.02)   # 端の目盛り（上限・下限）が消えないよう少し余白を取る
        self.plot.setMouseEnabled(x=True, y=False)
        self.plot.hideButtons()
        self.plot.disableAutoRange()   # 横軸は setXRange で明示的に決める（データ更新で勝手に広がらないように）
        self.plot.showGrid(x=False, y=True, alpha=0.3)
        self.plot.getAxis("bottom").setStyle(showValues=False)
        self.plot.getAxis("left").setTicks([[(lo, f"{lo:g}"), ((lo + hi) / 2, f"{(lo + hi) / 2:g}"), (hi, f"{hi:g}")]])
        self.plot.getAxis("left").setWidth(48)
        pad = (hi - lo) * 0.02
        self.plot.getPlotItem().getViewBox().setLimits(yMin=lo - pad, yMax=hi + pad)
        self.curves = {}
        for k in chart.kinds:
            c = pg.PlotCurveItem(pen=pg.mkPen(_qcolor(Palette.for_kind(k)), width=2), connect="finite")
            self.plot.addItem(c)
            self.curves[k] = c
        self.now_line = pg.InfiniteLine(angle=90, pen=pg.mkPen(QColor("red"), width=2.5), movable=False)
        self.plot.addItem(self.now_line)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(12, 8, 12, 8)
        lay.setSpacing(12)
        lay.addLayout(head)
        lay.addWidget(self.plot)
        self.setStyleSheet("ChartWidget { background: palette(alternate-base); border-radius: 10px; }")

    def set_kind_visible(self, kind: str, on: bool):
        if on:
            self.visible_kinds.add(kind)
        else:
            self.visible_kinds.discard(kind)
        self.curves[kind].setVisible(on)
        self.legend_items[kind].setVisible(on)

    def update_series(self, times: np.ndarray, values: dict[str, np.ndarray], index_offset: int = 0):
        """times（秒）と values（kind -> float32，NaN = 未検出）を描く．間引きは通算番号で位相を固定する."""
        n = len(times)
        stride = max(1, n // MAX_POINTS)
        if stride > 1:
            # (i + offset) % stride == 0 の点だけ残す．NaN 境界は保てないが線の途切れは stride 以内の誤差
            sel = ((np.arange(n) + index_offset) % stride) == 0
            times = times[sel]
        for k, curve in self.curves.items():
            v = values.get(k)
            if v is None or len(v) == 0:
                curve.setData([], [])
                self.legend_values[k].setText("--")
                continue
            vv = v[sel] if stride > 1 else v
            lo, hi = M.Y_RANGE[k]
            curve.setData(times, np.clip(vv, lo, hi))
            last = v[-1]
            self.legend_values[k].setText("--" if np.isnan(last) else f"{last:.2f}")

    def set_x_range(self, lo: float, hi: float):
        self.plot.setXRange(lo, hi, padding=0)

    def set_now(self, x: float):
        self.now_line.setPos(x)


class GraphPanel(QWidget):
    """モードごとのグラフを縦に並べる．x 軸は全グラフで連動."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.mode = "upperBody"
        self.widgets: dict[str, ChartWidget] = {}
        self.hidden_charts: set[str] = set()
        self.hidden_kinds: set[str] = set()
        self.layout_ = QVBoxLayout(self)
        self.layout_.setContentsMargins(16, 12, 16, 12)
        self.layout_.setSpacing(14)
        # 横軸の連動は setXLink ではなく自前で行う（非表示で幅 0 のグラフがリンク先だと範囲が狂うため）
        self._syncing = False
        for c in M.CHARTS:
            w = ChartWidget(c)
            self.widgets[c.id] = w
            self.layout_.addWidget(w)
            w.plot.getPlotItem().getViewBox().sigXRangeChanged.connect(
                lambda vb, rng, src=w: self._on_x_range_changed(src, rng))
        self.layout_.addStretch(1)
        self.set_mode(self.mode)

    def _on_x_range_changed(self, src: ChartWidget, rng):
        """ユーザーのズーム / 移動を他の表示中グラフへ反映する."""
        if self._syncing or not src.isVisible():
            return
        self._syncing = True
        try:
            for w in self.widgets.values():
                if w is not src:
                    w.plot.setXRange(rng[0], rng[1], padding=0)
        finally:
            self._syncing = False

    def set_mode(self, mode: str):
        self.mode = mode
        self._apply_visibility()

    def set_chart_hidden(self, chart_id: str, hidden: bool):
        (self.hidden_charts.add if hidden else self.hidden_charts.discard)(chart_id)
        self._apply_visibility()

    def set_kind_hidden(self, kind: str, hidden: bool):
        (self.hidden_kinds.add if hidden else self.hidden_kinds.discard)(kind)
        for w in self.widgets.values():
            if kind in w.curves:
                w.set_kind_visible(kind, not hidden)
        self._apply_visibility()

    def _apply_visibility(self):
        for cid, w in self.widgets.items():
            show = (w.chart.mode == self.mode and cid not in self.hidden_charts
                    and any(k not in self.hidden_kinds for k in w.chart.kinds))
            w.setVisible(show)

    def visible_widgets(self) -> list[ChartWidget]:
        return [w for w in self.widgets.values() if w.isVisible()]

    def set_mouse_enabled(self, on: bool):
        for w in self.widgets.values():
            w.plot.setMouseEnabled(x=on, y=False)
