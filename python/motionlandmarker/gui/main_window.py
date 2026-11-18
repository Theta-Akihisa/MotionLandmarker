"""メインウィンドウ．Swift 版 ContentView / AppState の移植."""
from __future__ import annotations

import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
from PySide6.QtCore import Qt, QTimer, QSettings, QUrl, Signal, QMetaObject, Q_ARG, Slot
from PySide6.QtGui import QAction, QDesktopServices, QFont, QKeySequence, QShortcut
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout, QLabel,
                               QComboBox, QCheckBox, QPushButton, QSplitter, QScrollArea, QSlider,
                               QFileDialog, QMessageBox, QToolButton, QProgressBar, QSizePolicy,
                               QButtonGroup, QFrame)

from .. import metrics as M
from .. import renderer
from ..detectors import MODE_SINGLE, MODE_MULTI, MAX_PEOPLE
from ..renderer import DrawOptions
from ..timeline import PeopleTrack, Timeline, recording_parts, variant_path
from .app_icon import app_icon, set_windows_app_id
from .camera import Camera
from .graphs import GraphPanel
from .video_view import VideoView
from .worker import WorkerThread

ORG, APP = "MotionLandmarker", "MotionLandmarker"
LIVE_WINDOW = 10.0
CHART_HZ = 120

STYLES = [("raw", "生映像"), ("skeleton", "skeleton"), ("overlay", "overlay"), ("hidden", "非表示")]


def default_output_root() -> Path:
    return Path.home() / "Documents" / "MotionLandmarker" / "results_data"


class Playback:
    """録画の再生（cv2 で読み，QTimer で進める）．raw / skeleton / overlay の差し替えと非表示に対応．

    複数人モードの録画で人物ごとの Box（people.json の bbox / slot）があれば people に読み込む．
    overlay 表示中は人物ごとの Box を生映像から作り直すため，raw 動画も並行して読む（raw_frame）．
    """

    def __init__(self, on_frame, on_tick):
        self.on_frame = on_frame
        self.on_tick = on_tick
        self.cap: cv2.VideoCapture | None = None
        self.url: Path | None = None
        self.file: Path | None = None
        self.variant = "overlay"
        self.available: set[str] = set()
        self.fps = 30.0
        self.frames = 0
        self.index = 0
        self.playing = False
        self.timer = QTimer()
        self.timer.setSingleShot(True)      # フレームごとに次の間隔を決めて撃ち直す（可変フレーム間隔に対応）
        self.timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.timer.timeout.connect(self._step)
        self.timeline: Timeline | None = None
        self.people: PeopleTrack | None = None
        self.raw_cap: cv2.VideoCapture | None = None
        self.raw_frame: np.ndarray | None = None
        self.size = (16, 9)

    @property
    def duration(self) -> float:
        t = self.timeline
        if t is not None and len(t):
            return float(t.timestamps[-1] - t.first_timestamp) / 1000.0
        return self.frames / self.fps if self.fps else 0.0

    @property
    def seconds(self) -> float:
        """再生位置（秒）．CSV の timestamp_ms があればそれを使う（動画のフレーム番号 == CSV の行番号）."""
        t = self.timeline
        if t is not None and 0 <= self.index < len(t):
            return float(t.timestamps[self.index] - t.first_timestamp) / 1000.0
        return self.index / self.fps if self.fps else 0.0

    def _interval_ms(self) -> int:
        """次のフレームまでの間隔（ms）．timestamp_ms があればその差，無ければ 1 / fps."""
        t = self.timeline
        if t is not None and 0 <= self.index + 1 < len(t):
            return max(1, int(t.timestamps[self.index + 1] - t.timestamps[self.index]))
        return max(1, int(round(1000.0 / self.fps)))

    def open(self, url: Path):
        self.close()
        self.url = url
        parts = recording_parts(url)
        if parts:
            stem, root, variant = parts
            self.available = {v for v in ("raw", "skeleton", "overlay") if variant_path(root, stem, v).exists()} | {"hidden"}
            if self.variant == "hidden" or self.variant not in self.available:
                self.variant = variant
            self.file = variant_path(root, stem, self.variant)
        else:
            self.available = {"hidden"}
            self.file = url
        self.timeline = Timeline.load_for_video(url)
        self.people = PeopleTrack.load_for_video(url)
        if self.people is not None and parts and "raw" in self.available:
            self.raw_cap = cv2.VideoCapture(str(variant_path(parts[1], parts[0], "raw")))
        self._open_file(self.file)
        self.index = 0
        self.play()

    def _open_file(self, path: Path):
        if self.cap is not None:
            self.cap.release()
        self.cap = cv2.VideoCapture(str(path))
        self.fps = self.cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.frames = int(self.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        self.size = (int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))

    def set_variant(self, v: str):
        if v == self.variant or self.url is None:
            return
        old = self.variant
        self.variant = v
        if v == "hidden":
            self.on_frame(None)
            return
        parts = recording_parts(self.url)
        if parts is None:
            return
        stem, root, _ = parts
        target = variant_path(root, stem, v)
        if target.exists() and target != self.file:
            self.file = target
            self._open_file(target)
        self.seek(self.index)

    def play(self):
        if self.cap is None:
            return
        if self.frames and self.index >= self.frames - 1:
            self.seek(0)
        self.playing = True
        self.timer.start(self._interval_ms())

    def pause(self):
        self.playing = False
        self.timer.stop()

    def toggle(self):
        self.pause() if self.playing else self.play()

    def seek(self, index: int):
        if self.cap is None:
            return
        self.index = max(0, min(index, max(0, self.frames - 1)))
        self.cap.set(cv2.CAP_PROP_POS_FRAMES, self.index)
        if self.raw_cap is not None:
            self.raw_cap.set(cv2.CAP_PROP_POS_FRAMES, self.index)
        ok, frame = self._read()
        if ok:
            self.on_frame(None if self.variant == "hidden" else frame)
        self.on_tick()

    def step(self, delta: int):
        self.pause()
        self.seek(self.index + delta)

    def _read(self):
        """表示中の動画を 1 フレーム読む．overlay 表示で人物ごとの Box があるときは生映像も同じ位置を読む．

        生映像は overlay のときだけ読み進める（他の表示から overlay へ切り替えるときは seek で位置を揃え直す）．
        """
        ok, frame = self.cap.read()
        self.raw_frame = None
        if self.raw_cap is not None and self.variant == "overlay":
            ok_raw, raw = self.raw_cap.read()
            self.raw_frame = raw if ok_raw else None
        return ok, frame

    def _step(self):
        if self.cap is None:
            return
        ok, frame = self._read()
        if not ok:
            self.pause()
            return
        self.index = int(self.cap.get(cv2.CAP_PROP_POS_FRAMES)) - 1
        self.on_frame(None if self.variant == "hidden" else frame)
        self.on_tick()
        if self.playing:
            self.timer.start(self._interval_ms())

    def close(self):
        self.pause()
        if self.cap is not None:
            self.cap.release()
            self.cap = None
        if self.raw_cap is not None:
            self.raw_cap.release()
            self.raw_cap = None
        self.raw_frame = None
        self.url = None
        self.timeline = None
        self.people = None


class MainWindow(QMainWindow):
    _submit = Signal(object, int)
    _set_mode = Signal(int)
    _run_import = Signal(str, str, bool)

    def __init__(self):
        super().__init__()
        self.setWindowTitle("MotionLandmarker")
        self.settings = QSettings(ORG, APP)
        self.output_root = Path(self.settings.value("outputRoot", str(default_output_root())))
        self.person_mode = int(self.settings.value("personMode", MODE_SINGLE))
        self.live_style = self.settings.value("liveStyle", "overlay")
        self.metric_mode = self.settings.value("metricMode", "upperBody")
        self.draw_options = DrawOptions()
        self.history = M.History()
        # 複数人モード：人物番号ごとの履歴（毎フレーム全員分を積む．いない人は NaN）
        self.slot_histories = {s: M.History() for s in range(1, MAX_PEOPLE + 1)}
        self.inference_times: list[float] = []
        self.recording = False
        self.importing = False
        self.switching_mode = False
        self.worker_ready = False
        self.frame_seen = False          # カメラの実フレームを 1 枚以上処理したか（録画サイズが決まる）
        self.history_dirty = False
        self.last_overlay: Path | None = None
        self.playback = Playback(self._on_playback_frame, self._on_playback_tick)
        self.t0 = time.monotonic()

        self.wt = WorkerThread()
        w = self.wt.worker
        w.result.connect(self._on_result)
        w.ready.connect(self._on_worker_ready)
        w.failed.connect(self._on_worker_failed)
        w.mode_changed.connect(self._on_mode_changed)
        w.import_progress.connect(self._on_import_progress)
        w.import_finished.connect(self._on_import_finished)
        self._submit.connect(w.process)
        self._set_mode.connect(w.set_mode)
        self._run_import.connect(w.run_import)

        self.camera = Camera(self)
        self.camera.frame.connect(self._on_camera_frame)
        self.camera.devices_changed.connect(self._refresh_cameras)
        self.camera.error.connect(self._on_camera_error)

        self._build_ui()
        self._apply_scale(int(self.settings.value("uiScaleStep", 0)))
        self._refresh_cameras()
        self._refresh_last_recording()
        QMetaObject.invokeMethod(w, "warm_up", Qt.ConnectionType.QueuedConnection)
        if self.person_mode == MODE_MULTI:
            self.switching_mode = True
            self._set_mode.emit(MODE_MULTI)

        self.chart_timer = QTimer(self)
        self.chart_timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.chart_timer.timeout.connect(self._tick_charts)
        self.chart_timer.start(int(1000 / CHART_HZ))

    # ---------------------------------------------------------------- UI
    def _build_ui(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # 上部バー：左から 人数（1人 / 複数人），表示の切り替え（2×2），部位とミラー（2 行），状態，カメラ
        top = QHBoxLayout(); top.setContentsMargins(12, 10, 12, 10); top.setSpacing(12)
        self.style_label = QLabel("表示")
        # 表示の切り替え：排他のトグルボタンを 2×2 に並べる（再生中は録画に無い種類を無効にする）
        self.style_group = QButtonGroup(self)
        self.style_group.setExclusive(True)
        self.style_buttons: dict[str, QToolButton] = {}
        style_grid = QGridLayout(); style_grid.setContentsMargins(0, 0, 0, 0); style_grid.setSpacing(4)
        style_grid.setVerticalSpacing(2)
        for i, (key, label) in enumerate(STYLES):
            b = QToolButton(); b.setText(label); b.setCheckable(True)
            b.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
            b.setMinimumWidth(64)
            self.style_group.addButton(b, i)
            self.style_buttons[key] = b
            style_grid.addWidget(b, i // 2, i % 2)
        self.style_buttons[self.live_style].setChecked(True)
        self.style_group.idClicked.connect(lambda i: self._on_style_changed(STYLES[i][0]))
        self.part_checks = {}
        for key, label in (("face", "顔"), ("pose", "体（pose）"), ("left_hand", "左手"), ("right_hand", "右手")):
            cb = QCheckBox(label); cb.setChecked(True)
            cb.toggled.connect(lambda on, k=key: self._on_part_toggled(k, on))
            self.part_checks[key] = cb
        self.mirror_check = QCheckBox("ミラー")
        self.mirror_check.setChecked(self.settings.value("mirrorLive", "false") == "true")
        self.mirror_check.setToolTip("表示を左右反転する（鏡のように見せる）．録画や CSV の座標は変わらない")
        self.mirror_check.toggled.connect(self._on_mirror_toggled)
        self.status_label = QLabel("モデルを読み込み中…")
        self.person_combo = QComboBox()
        self.person_combo.addItem("1人", MODE_SINGLE); self.person_combo.addItem("複数人", MODE_MULTI)
        self.person_combo.setCurrentIndex(0 if self.person_mode == MODE_SINGLE else 1)
        self.person_combo.currentIndexChanged.connect(self._on_person_mode_changed)
        self.person_combo.setToolTip("1人: Holistic / 複数人: YOLO で人物を検出し人物ごとに Holistic（uv sync --extra multi が必要）")
        self.camera_combo = QComboBox()
        self.camera_combo.currentIndexChanged.connect(self._on_camera_selected)
        person_box = QVBoxLayout(); person_box.setSpacing(4)
        person_box.addWidget(QLabel("人数")); person_box.addWidget(self.person_combo)
        # 部位とミラーは 2 行に並べる（1 行目: 顔，体，ミラー / 2 行目: 左手，右手）
        part_grid = QGridLayout(); part_grid.setContentsMargins(0, 0, 0, 0)
        part_grid.setHorizontalSpacing(8); part_grid.setVerticalSpacing(6)
        for (r, c), key in zip(((0, 0), (0, 1), (1, 0), (1, 1)), ("face", "pose", "left_hand", "right_hand")):
            part_grid.addWidget(self.part_checks[key], r, c)
        part_grid.addWidget(self.mirror_check, 0, 2)
        # ボタン：Record / Play はバーの中央，選んで再生・動画を処理・Reveal・保存先は右端に置く
        self.btn_record = self._big_button("⏺", "Record", self._toggle_recording, 72)
        self.btn_playrec = self._big_button("▶", "Play", self._toggle_playback, 72)
        self.btn_choose = self._big_button("📂", "選んで再生…", self._choose_playback)
        self.btn_reveal = self._big_button("🗂", "Reveal", self._reveal_output)
        self.btn_import = self._big_button("⬇", "動画を処理…", self._import_video)
        self.btn_outdir = self._big_button("⚙", "保存先…", self._choose_output_root)
        self.btn_record.setShortcut(QKeySequence("Ctrl+R"))
        self.left_controls = QWidget()
        lcl = QHBoxLayout(self.left_controls); lcl.setContentsMargins(0, 0, 0, 0); lcl.setSpacing(12)
        lcl.addLayout(person_box)
        sep = QFrame(); sep.setFrameShape(QFrame.Shape.VLine); lcl.addWidget(sep)
        style_box = QVBoxLayout(); style_box.setSpacing(4)
        style_box.addWidget(self.style_label); style_box.addLayout(style_grid)
        lcl.addLayout(style_box)
        lcl.addLayout(part_grid)
        lcl.addStretch(1)
        self.right_buttons = QWidget()
        rl = QHBoxLayout(self.right_buttons); rl.setContentsMargins(0, 0, 0, 0); rl.setSpacing(0)
        rl.addStretch(1)
        for b in (self.btn_choose, self.btn_import, self.btn_reveal, self.btn_outdir):
            rl.addWidget(b)
        # Record / Play を常にバー全体の中央に置くため，左（設定）と右（ボタン群）の領域を同じ幅にする
        # （広い方の幅に合わせる．幅は _apply_scale で合わせ直す．ボタンを小さくして窓の最小幅を抑えている）
        top.addWidget(self.left_controls, 1)
        top.addWidget(self.btn_record); top.addWidget(self.btn_playrec)
        top.addWidget(self.right_buttons, 1)
        root.addLayout(top)

        # 映像
        self.video = VideoView()
        self.video.mirror = self.mirror_check.isChecked()
        self.video.resized.connect(self._on_video_resized)

        # 再生バー（再生中だけ表示）
        self.transport = QWidget()
        tl = QHBoxLayout(self.transport); tl.setContentsMargins(12, 6, 16, 6); tl.setSpacing(12)
        self.btn_back = QToolButton(); self.btn_back.setText("⏮"); self.btn_back.setToolTip("1 フレーム戻る")
        self.btn_play = QToolButton(); self.btn_play.setText("▶"); self.btn_play.setToolTip("再生 / 一時停止（スペース）")
        self.btn_fwd = QToolButton(); self.btn_fwd.setText("⏭"); self.btn_fwd.setToolTip("1 フレーム進む")
        for b in (self.btn_back, self.btn_play, self.btn_fwd):
            f = b.font(); f.setPointSizeF(f.pointSizeF() * 1.8); b.setFont(f)
        self.btn_back.clicked.connect(lambda: self.playback.step(-1))
        self.btn_play.clicked.connect(self.playback.toggle)
        self.btn_fwd.clicked.connect(lambda: self.playback.step(1))
        self.time_label = QLabel("0:00.00\n0:00.00")
        self.seek_slider = QSlider(Qt.Orientation.Horizontal)
        self.seek_slider.sliderMoved.connect(lambda v: self.playback.seek(v))
        self.seek_slider.sliderPressed.connect(self.playback.pause)
        tl.addWidget(self.btn_back); tl.addWidget(self.btn_play); tl.addWidget(self.btn_fwd); tl.addWidget(self.time_label)
        tl.addWidget(self.seek_slider, 1)
        self.transport.setVisible(False)

        # 状態表示とカメラの選択（映像とグラフの間の 1 行）
        status_row = QWidget()
        sl = QHBoxLayout(status_row); sl.setContentsMargins(12, 6, 12, 2); sl.setSpacing(8)
        sl.addWidget(self.status_label); sl.addStretch(1)
        sl.addWidget(QLabel("カメラ")); sl.addWidget(self.camera_combo)
        self.outdir_label = QLabel()
        self.outdir_label.setStyleSheet("color: gray")
        self.msg_label = QLabel(); self.msg_label.setStyleSheet("color: gray")
        lower_top = QWidget()
        ltl = QVBoxLayout(lower_top); ltl.setContentsMargins(0, 0, 0, 0); ltl.setSpacing(2)
        ltl.addWidget(self.transport); ltl.addWidget(status_row)
        ltl.addWidget(self.outdir_label); ltl.addWidget(self.msg_label)
        self._update_outdir_label()

        # グラフ部：モード切り替え＋チェックボックス列＋グラフ
        graphs_area = QWidget()
        gl = QVBoxLayout(graphs_area); gl.setContentsMargins(0, 0, 0, 0); gl.setSpacing(0)
        mode_bar = QHBoxLayout(); mode_bar.setContentsMargins(12, 6, 12, 6)
        self.mode_combo = QComboBox()
        for key, label in M.MODES.items():
            self.mode_combo.addItem(label, key)
        self.mode_combo.setCurrentIndex(list(M.MODES).index(self.metric_mode))
        self.mode_combo.currentIndexChanged.connect(self._on_metric_mode_changed)
        self.mode_desc = QLabel(); self.mode_desc.setStyleSheet("color: gray")
        # 複数人モードだけ：波形に出す人物（全体映像の枠の番号）を選ぶ
        self.slot_label = QLabel("人物")
        self.slot_combo = QComboBox()
        for slot in range(1, MAX_PEOPLE + 1):
            self.slot_combo.addItem(f"{slot}人目", slot)
        self.slot_combo.setToolTip("複数人モード：波形に出す人物（映像の枠の番号）．その人がいないフレームは欠損として扱う")
        self.slot_combo.currentIndexChanged.connect(self._on_slot_changed)
        self.zoom_label = QLabel(""); self.zoom_label.setStyleSheet("color: gray")
        self.btn_zoom_all = QPushButton("全体"); self.btn_zoom_all.clicked.connect(self._zoom_all); self.btn_zoom_all.setVisible(False)
        mode_bar.addWidget(self.mode_combo); mode_bar.addSpacing(12)
        mode_bar.addWidget(self.slot_label); mode_bar.addWidget(self.slot_combo); mode_bar.addSpacing(12)
        mode_bar.addWidget(self.mode_desc); mode_bar.addStretch(1)
        mode_bar.addWidget(self.zoom_label); mode_bar.addWidget(self.btn_zoom_all)
        gl.addLayout(mode_bar)
        line = QFrame(); line.setFrameShape(QFrame.Shape.HLine); gl.addWidget(line)

        self.graph_panel = GraphPanel()
        graph_scroll = QScrollArea(); graph_scroll.setWidgetResizable(True); graph_scroll.setWidget(self.graph_panel)
        graph_scroll.setFrameShape(QFrame.Shape.NoFrame)
        column = QWidget()
        cl = QVBoxLayout(column); cl.setContentsMargins(12, 12, 12, 12); cl.setSpacing(4)
        head = QLabel("グラフ項目"); f = head.font(); f.setBold(True); f.setPointSizeF(f.pointSizeF() * 1.3); head.setFont(f)
        cl.addWidget(head)
        self.chart_checks: dict[str, QCheckBox] = {}
        self.kind_checks: dict[str, QCheckBox] = {}
        for c in M.CHARTS:
            cb = QCheckBox(c.title); fb = cb.font(); fb.setBold(True); cb.setFont(fb); cb.setChecked(True)
            cb.toggled.connect(lambda on, cid=c.id: self.graph_panel.set_chart_hidden(cid, not on))
            cl.addWidget(cb); self.chart_checks[c.id] = cb
            for k in c.kinds:
                kb = QCheckBox(M.LABELS[k]); kb.setChecked(True)
                kb.toggled.connect(lambda on, kk=k: self.graph_panel.set_kind_hidden(kk, not on))
                kb.setStyleSheet("margin-left: 18px")
                cl.addWidget(kb); self.kind_checks[k] = kb
        cl.addStretch(1)
        column_scroll = QScrollArea(); column_scroll.setWidgetResizable(True); column_scroll.setWidget(column)
        column_scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.hsplit = QSplitter(Qt.Orientation.Horizontal)
        self.hsplit.addWidget(column_scroll); self.hsplit.addWidget(graph_scroll)
        self.hsplit.setStretchFactor(1, 1)
        self.hsplit.setSizes([int(self.settings.value("columnWidth", 270)), 900])
        self.hsplit.splitterMoved.connect(lambda *_: self.settings.setValue("columnWidth", self.hsplit.sizes()[0]))
        gl.addWidget(self.hsplit, 1)

        lower = QWidget()
        ll = QVBoxLayout(lower); ll.setContentsMargins(0, 0, 0, 0); ll.setSpacing(0)
        ll.addWidget(lower_top); ll.addWidget(graphs_area, 1)

        self.vsplit = QSplitter(Qt.Orientation.Vertical)
        self.vsplit.addWidget(self.video); self.vsplit.addWidget(lower)
        self.vsplit.setStretchFactor(1, 1)
        self.vsplit.setSizes([int(self.settings.value("videoHeight", 360)), 600])
        self.vsplit.splitterMoved.connect(lambda *_: self.settings.setValue("videoHeight", self.vsplit.sizes()[0]))
        root.addWidget(self.vsplit, 1)
        self.setCentralWidget(central)
        self.resize(1280, 1000)
        self._apply_metric_mode()
        self._update_chart_checks()
        self._update_slot_selector()
        self._on_style_changed(self.live_style)

        # メニュー / ショートカット
        view_menu = self.menuBar().addMenu("表示")
        for text, seq, step in (("拡大", QKeySequence.StandardKey.ZoomIn, +1), ("縮小", QKeySequence.StandardKey.ZoomOut, -1)):
            act = QAction(text, self); act.setShortcut(seq); act.triggered.connect(lambda _, s=step: self._apply_scale(self.scale_step + s))
            view_menu.addAction(act)
        act = QAction("実際のサイズ", self); act.setShortcut(QKeySequence("Ctrl+0")); act.triggered.connect(lambda: self._apply_scale(0))
        view_menu.addAction(act)
        act2 = QAction("拡大 ", self); act2.setShortcut(QKeySequence("Ctrl+=")); act2.triggered.connect(lambda: self._apply_scale(self.scale_step + 1))
        self.addAction(act2)
        QShortcut(QKeySequence(Qt.Key.Key_Space), self, activated=self._space)

    def _big_button(self, icon: str, label: str, slot, min_width: int = 64) -> QToolButton:
        b = QToolButton()
        b.setText(f"{icon}\n{label}")
        b.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        b.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Preferred)
        b.setAutoRaise(True)
        b.clicked.connect(slot)
        b.setMinimumHeight(48)
        b.setMinimumWidth(min_width)
        return b

    # ---------------------------------------------------------------- scale
    def _apply_scale(self, step: int):
        """⌘+ / ⌘- / ⌘0：アプリ全体の文字サイズを段階的に変える（1 段あたり約 12%）."""
        self.scale_step = max(-3, min(4, step))
        self.settings.setValue("uiScaleStep", self.scale_step)
        base = 13.0 * (1.12 ** self.scale_step)
        f = QApplication.font(); f.setPointSizeF(base)
        QApplication.setFont(f)
        # 既存のウィジェットにも反映する．太字のものは太字を保ち，強調している文字は倍率を保つ
        for w in QApplication.allWidgets():
            wf = QFont(f)
            if w.font().bold():
                wf.setBold(True)
            w.setFont(wf)
        for cw in self.graph_panel.widgets.values():
            ft = QFont(f); ft.setBold(True); ft.setPointSizeF(base * 1.3); cw.title_label.setFont(ft)
        for b in (self.btn_back, self.btn_play, self.btn_fwd):
            fb = QFont(f); fb.setPointSizeF(base * 1.8); b.setFont(fb)
        for lab in self.findChildren(QLabel):
            if lab.text() == "グラフ項目":
                fh = QFont(f); fh.setBold(True); fh.setPointSizeF(base * 1.3); lab.setFont(fh)
        # 文字の大きさが反映されてから幅を測る
        QTimer.singleShot(0, self._balance_top_bar)

    def _balance_top_bar(self):
        """上部バーの左（設定）と右（ボタン群）を同じ幅にして，Record / Play を中央に保つ."""
        for side in (self.left_controls, self.right_buttons):
            side.setMinimumWidth(0)
            side.layout().invalidate()
        side_w = max(self.left_controls.sizeHint().width(), self.right_buttons.sizeHint().width())
        for side in (self.left_controls, self.right_buttons):
            side.setMinimumWidth(side_w)

    @staticmethod
    def _bold(f: QFont) -> QFont:
        b = QFont(f); b.setBold(True); return b

    # ---------------------------------------------------------------- camera
    def _refresh_cameras(self):
        devices = Camera.devices()
        self.camera_combo.blockSignals(True)
        current = self.camera_combo.currentData()
        self.camera_combo.clear()
        for d in devices:
            self.camera_combo.addItem(d.description(), d.id())
        if devices:
            idx = next((i for i, d in enumerate(devices) if d.id() == current), -1)
            if idx < 0:
                idx = 0
            self.camera_combo.setCurrentIndex(idx)
        self.camera_combo.blockSignals(False)
        self._devices = devices
        if devices:
            self._on_camera_selected(self.camera_combo.currentIndex())
        else:
            self.video.message = "カメラが見つかりません"
            self.video.update()

    def _on_camera_selected(self, index: int):
        if index < 0 or index >= len(getattr(self, "_devices", [])):
            return
        d = self._devices[index]
        self.camera.select(d)
        self.video.badge_bl = d.description()
        self.video.message = None
        self.video.update()

    def _on_camera_error(self, msg: str):
        self.video.message = f"カメラのエラー: {msg}\n別のカメラを選ぶか，Windows の設定 > プライバシーとセキュリティ > カメラ でデスクトップアプリの許可を確認してください"
        self.video.update()
        self.msg_label.setText(f"カメラ: {msg}")
        print("camera error:", msg, file=sys.stderr, flush=True)

    def _on_camera_frame(self, bgr: np.ndarray, ms: int):
        if self.playback.url is not None or self.importing:
            return
        w = self.wt.worker
        if not self.worker_ready or w.busy.is_set():
            return
        w.busy.set()
        self._submit.emit(bgr, ms)

    # ---------------------------------------------------------------- worker callbacks
    def _on_worker_ready(self):
        self.worker_ready = True
        self._update_status()
        self._refresh_buttons()

    def _on_worker_failed(self, msg: str):
        self.status_label.setText(f"推論エラー: {msg}")
        self.status_label.setToolTip(msg)
        self.status_label.setStyleSheet("color: red")
        self.switching_mode = False
        print("inference error:", msg, file=sys.stderr, flush=True)

    def _on_mode_changed(self, mode: int):
        self.switching_mode = False
        self.person_mode = mode
        self.settings.setValue("personMode", mode)
        self.slot_histories = {s: M.History() for s in range(1, MAX_PEOPLE + 1)}
        self.history_dirty = True
        self._update_slot_selector()
        self._update_status()

    def _on_result(self, res):
        """res は pipeline.Processed（ライブと動画の処理中）."""
        self.frame_seen = True
        self.history_dirty = True
        if self.playback.url is None:
            self.video.set_tiles(res.image, res.tiles)
            if self.live_style == "hidden":
                self.video.message = "映像は非表示（推論と波形は動作中）"
            elif self.video.message and self.video.message.startswith("映像は非表示"):
                self.video.message = None
        t = time.monotonic() - self.t0
        self.history.push(res.metrics, t)
        if self.person_mode == MODE_MULTI:
            for slot, h in self.slot_histories.items():
                h.push(res.slot_metrics.get(slot, {}), t)
        now = time.monotonic()
        self.inference_times.append(now)
        self.inference_times = [t for t in self.inference_times if t > now - 2]
        if self.recording:
            self.video.badge_tr = f"REC {res.recorded}"
        self._update_status()

    def _update_status(self):
        if not self.worker_ready:
            return
        if self.switching_mode:
            self.status_label.setText("モードを切り替え中（モデルの読み込み）…")
        else:
            fps = len(self.inference_times) / 2.0
            accel = self.wt.worker.pipeline.detector.accel
            self.status_label.setText(f"MediaPipe {fps:.1f} fps" + (f"（{accel}）" if accel else ""))
        self.status_label.setStyleSheet("")

    # ---------------------------------------------------------------- controls
    def _set_style_choices(self, keys, current: str):
        """表示の切り替えボタンのうち keys だけを有効にし，current を選んだ状態にする."""
        for k, b in self.style_buttons.items():
            b.setEnabled(k in keys)
            b.setChecked(k == current)

    def _on_style_changed(self, key: str):
        if self.playback.url is not None:
            self.playback.set_variant(key)
            self.video.message = "映像は非表示（波形のみ再生中）" if self.playback.variant == "hidden" else None
            self.video.update()
            return
        self.live_style = key
        self.settings.setValue("liveStyle", self.live_style)
        self.wt.worker.pipeline.live_style = self.live_style
        show_parts = self.live_style in ("skeleton", "overlay")
        for cb in self.part_checks.values():
            cb.setVisible(show_parts)
        if self.live_style == "hidden":
            self.video.set_bgr(None)
            self.video.message = "映像は非表示（推論と波形は動作中）"
        else:
            self.video.message = None
        self.video.update()

    def _on_part_toggled(self, key: str, on: bool):
        setattr(self.draw_options, key, on)
        self.wt.worker.pipeline.draw_options = DrawOptions(**vars(self.draw_options))

    def _on_mirror_toggled(self, on: bool):
        self.video.mirror = on
        self.settings.setValue("mirrorLive", "true" if on else "false")
        self.video.update()

    def _on_person_mode_changed(self, idx: int):
        mode = self.person_combo.itemData(idx)
        if mode == self.person_mode or self.recording or self.importing:
            return
        self.switching_mode = True
        self._update_status()
        self._set_mode.emit(mode)

    def _on_video_resized(self):
        """映像の表示域の大きさが変わったら，人物タイルの切り出しの縦横比をマスに合わせ直す."""
        self.wt.worker.pipeline.tile_aspects = self.video.tile_aspects()
        if self.playback.url is not None and not self.playback.playing:
            self.playback.seek(self.playback.index)

    def _on_slot_changed(self, idx: int):
        if self.playback.url is not None:
            self._load_playback_timeline()
        else:
            self.history_dirty = True

    def _update_slot_selector(self):
        """人物のセレクタは複数人モード（ライブ）か，人物番号のある録画の再生中だけ出す."""
        if self.playback.url is not None:
            on = self.playback.people is not None
        else:
            on = self.person_mode == MODE_MULTI
        self.slot_label.setVisible(on)
        self.slot_combo.setVisible(on)

    def _live_history(self) -> M.History:
        if self.person_mode == MODE_MULTI:
            return self.slot_histories[self.slot_combo.currentData()]
        return self.history

    def _on_metric_mode_changed(self, idx: int):
        self.metric_mode = self.mode_combo.itemData(idx)
        self.settings.setValue("metricMode", self.metric_mode)
        self._apply_metric_mode()

    def _apply_metric_mode(self):
        self.graph_panel.set_mode(self.metric_mode)
        self.mode_desc.setText("頭・体の向きと手首の位置・速度" if self.metric_mode == "upperBody"
                               else "肘から手までの動き（前腕の角度・手の向き・手の開き・手首の速度）")
        self._update_chart_checks()

    def _update_chart_checks(self):
        shown = {c.id for c in M.charts_for(self.metric_mode)}
        kinds = {k for c in M.charts_for(self.metric_mode) for k in c.kinds}
        for cid, cb in self.chart_checks.items():
            cb.setVisible(cid in shown)
        for k, cb in self.kind_checks.items():
            cb.setVisible(k in kinds)

    def _space(self):
        if self.playback.url is not None:
            self.playback.toggle()

    # ---------------------------------------------------------------- recording
    def _toggle_recording(self):
        if self.recording:
            r = self.wt.worker.pipeline.stop_recording()
            self.recording = False
            self.btn_record.setText("⏺\nRecord")
            self.video.badge_tr = None
            if r is not None:
                self.last_overlay = r.overlay_url
                msg = f"{r.frame_count} フレームを保存: {self.output_root}"
                self.msg_label.setText(msg)
            self._refresh_buttons()
            return
        if not self.worker_ready or self.importing or self.switching_mode:
            return
        if self.playback.url is not None:
            self._stop_playback()
        if not self.frame_seen:
            self.msg_label.setText("カメラの映像が届いてから録画を始めてください")
            return
        stem = "live_" + datetime.now().strftime("%Y%m%d_%H%M%S")
        try:
            # mp4 は固定フレームレートでしか書けないため，実測の推論レートを使う（正確な時刻は CSV の timestamp_ms）
            fps = len(self.inference_times) / 2.0
            self.wt.worker.pipeline.fps_hint = max(5.0, min(60.0, fps)) if fps > 0 else 30.0
            self.wt.worker.pipeline.start_recording(self.output_root, stem, self.person_mode == MODE_MULTI)
        except Exception as e:
            self.msg_label.setText(f"録画を開始できません: {e}")
            return
        self.recording = True
        self.btn_record.setText("⏹\nStop")
        self.msg_label.setText("")
        self._refresh_buttons()

    def _refresh_buttons(self):
        busy = self.recording or self.importing
        self.btn_playrec.setEnabled(self.last_overlay is not None and not busy)
        self.btn_choose.setEnabled(not busy)
        self.btn_import.setEnabled(self.worker_ready and not busy)
        self.btn_outdir.setEnabled(not self.recording)
        self.person_combo.setEnabled(not busy and not self.switching_mode)
        self.btn_playrec.setText("⏹\nLive" if self.playback.url is not None else "▶\nPlay")

    def _refresh_last_recording(self):
        d = self.output_root / "video_overlay"
        files = sorted(d.glob("*.mp4"), key=lambda p: p.stat().st_mtime) if d.is_dir() else []
        self.last_overlay = files[-1] if files else None
        self._refresh_buttons()

    # ---------------------------------------------------------------- playback
    def _toggle_playback(self):
        if self.playback.url is not None:
            self._stop_playback()
        elif self.last_overlay is not None:
            self._start_playback(self.last_overlay)

    def _choose_playback(self):
        d = self.output_root / "video_overlay"
        path, _ = QFileDialog.getOpenFileName(self, "再生する録画を選ぶ", str(d if d.is_dir() else self.output_root),
                                              "動画 (*.mp4 *.mov *.m4v)")
        if path:
            self._start_playback(Path(path))

    def _start_playback(self, url: Path):
        self.camera.stop()
        self.playback.open(url)
        self.transport.setVisible(True)
        self.btn_zoom_all.setVisible(True)
        self.style_label.setText("再生映像")
        self._set_style_choices(self.playback.available, self.playback.variant)
        for cb in self.part_checks.values():
            cb.setVisible(False)
        self.mirror_check.setVisible(False)
        self.seek_slider.setRange(0, max(0, self.playback.frames - 1))
        self.video.badge_tl = f"再生中: {url.name}" + ("" if self.playback.timeline else "（波形データなし）")
        self.graph_panel.set_mouse_enabled(True)
        self._update_slot_selector()
        self._load_playback_timeline()
        self._zoom_all()
        self._refresh_buttons()

    def _stop_playback(self):
        self.playback.close()
        self.transport.setVisible(False)
        self.btn_zoom_all.setVisible(False)
        self.zoom_label.setText("")
        self.style_label.setText("表示")
        self._set_style_choices([k for k, _ in STYLES], self.live_style)
        self._on_style_changed(self.live_style)
        self._update_slot_selector()
        self.history_dirty = True
        self.mirror_check.setVisible(True)
        self.video.badge_tl = None
        self.video.set_bgr(None)
        self.graph_panel.set_mouse_enabled(False)
        if not self.importing:
            self.camera.resume()
        self._refresh_buttons()

    def _on_playback_frame(self, bgr):
        pb = self.playback
        tiles = []
        if bgr is not None and pb.people is not None:
            # overlay は生映像から切り出して描き直す（生映像が無い録画では overlay 映像をそのまま切り出す）
            style, bg = pb.variant, bgr
            if style == "overlay":
                if pb.raw_frame is not None:
                    bg = pb.raw_frame
                else:
                    style = "raw"
            people = pb.people.people_at(pb.index)
            count = 1 + max((q.slot for q in people), default=0)
            aspect = self.video.tile_aspects().get(count, renderer.TILE_ASPECT)
            tiles = renderer.person_tiles(people, bg, (bg.shape[1], bg.shape[0]), style, aspect=aspect)
        self.video.set_tiles(bgr, tiles)
        self.video.message = "映像は非表示（波形のみ再生中）" if bgr is None and self.playback.variant == "hidden" else None

    def _on_playback_tick(self):
        pb = self.playback
        self.btn_play.setText("⏸" if pb.playing else "▶")
        if not self.seek_slider.isSliderDown():
            self.seek_slider.setValue(pb.index)
        self.time_label.setText(f"{self._tstr(pb.seconds)}\n{self._tstr(pb.duration)}")
        self._follow_playback()

    @staticmethod
    def _tstr(s: float) -> str:
        m, sec = divmod(max(0.0, s), 60)
        return f"{int(m)}:{int(sec):02d}.{int((sec - int(sec)) * 100):02d}"

    def _load_playback_timeline(self):
        t = self.playback.timeline
        people = self.playback.people
        if people is not None and len(people):
            # 人物番号のある録画：選んだ人物の指標（いないフレームは NaN）．時刻は同じ行の timestamp_ms
            secs = (people.timestamps - people.timestamps[0]) / 1000.0
            values = people.slot_values.get(self.slot_combo.currentData(), {})
            for w in self.graph_panel.widgets.values():
                w.update_series(secs, values, 0, full=True)
            return
        for w in self.graph_panel.widgets.values():
            if t is None:
                w.update_series(np.zeros(0), {})
            else:
                w.update_series(t.seconds, t.values, 0, full=True)

    def _zoom_all(self):
        if self.playback.url is None:
            return
        d = max(0.001, self.playback.duration)
        for w in self.graph_panel.widgets.values():
            w.set_x_range(0, d)
        self.zoom_label.setText("ホイールで横軸をズーム，ドラッグで移動")

    def _follow_playback(self):
        ws = self.graph_panel.visible_widgets()
        if not ws:
            return
        lo, hi = ws[0].plot.viewRange()[0]
        t = self.playback.seconds
        d = max(0.001, self.playback.duration)
        if hi - lo < d - 0.01:
            self.zoom_label.setText(f"表示範囲 {lo:.2f} – {hi:.2f} 秒")
            if t < lo or t > hi:
                span = hi - lo
                nlo = min(max(t, 0), max(0, d - span))
                for w in self.graph_panel.widgets.values():
                    w.set_x_range(nlo, nlo + span)
        else:
            self.zoom_label.setText("ホイールで横軸をズーム，ドラッグで移動")
        for w in self.graph_panel.widgets.values():
            w.set_now(t)

    # ---------------------------------------------------------------- charts (live)
    def _tick_charts(self):
        if self.playback.url is not None:
            return
        now = time.monotonic() - self.t0
        dirty, self.history_dirty = self.history_dirty, False
        hist = self._live_history()
        for w in self.graph_panel.visible_widgets():
            if dirty:
                w.update_series(hist.times, hist.values, hist.start_index)
            w.set_x_range(now - LIVE_WINDOW, now)
            w.set_now(now)

    # ---------------------------------------------------------------- import / output
    def _import_video(self):
        if not self.worker_ready or self.recording or self.importing:
            return
        path, _ = QFileDialog.getOpenFileName(self, "処理する動画を選ぶ", "", "動画 (*.mp4 *.mov *.m4v *.avi *.mkv)")
        if not path:
            return
        if self.playback.url is not None:
            self._stop_playback()
        self.importing = True
        self.camera.stop()
        self.video.badge_tl = f"処理中: {Path(path).name}"
        self.btn_import.setText("✖\n中止")
        self.btn_import.clicked.disconnect()
        self.btn_import.clicked.connect(self._cancel_import)
        self._refresh_buttons()
        self._run_import.emit(path, str(self.output_root), self.person_mode == MODE_MULTI)

    def _cancel_import(self):
        self.wt.worker.cancel_import.set()

    def _on_import_progress(self, done: int, total: int):
        self.video.badge_tl = f"処理中: {done} / {total} フレーム"

    def _on_import_finished(self, recorder, error: str):
        self.importing = False
        self.btn_import.setText("⬇\n動画を処理…")
        self.btn_import.clicked.disconnect()
        self.btn_import.clicked.connect(self._import_video)
        self.video.badge_tl = None
        if recorder is None:
            self.msg_label.setText(f"動画の処理に失敗: {error}")
            self.camera.resume()
            self._refresh_last_recording()
            return
        self.msg_label.setText(f"{recorder.stem} を処理しました（{recorder.frame_count} フレーム）→ {self.output_root}")
        self.last_overlay = recorder.overlay_url
        self._refresh_buttons()
        self._start_playback(recorder.overlay_url)

    def _choose_output_root(self):
        path = QFileDialog.getExistingDirectory(self, "録画の保存先", str(self.output_root))
        if path:
            self.output_root = Path(path)
            self.settings.setValue("outputRoot", path)
            self._update_outdir_label()
            self._refresh_last_recording()

    def _update_outdir_label(self):
        self.outdir_label.setText(f"保存先: {self.output_root}")

    def _reveal_output(self):
        self.output_root.mkdir(parents=True, exist_ok=True)
        target = self.last_overlay if self.last_overlay else self.output_root
        if sys.platform == "darwin":
            subprocess.Popen(["open", "-R", str(target)] if self.last_overlay else ["open", str(target)])
        elif sys.platform == "win32":
            subprocess.Popen(["explorer", f"/select,{target}"] if self.last_overlay else ["explorer", str(target)])
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.output_root)))

    # ---------------------------------------------------------------- close
    def closeEvent(self, event):
        if self.recording:
            self._toggle_recording()
        self.playback.close()
        self.camera.stop()
        self.wt.stop()
        super().closeEvent(event)


def run() -> int:
    set_windows_app_id()
    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName(APP)
    app.setOrganizationName(ORG)
    app.setWindowIcon(app_icon())
    win = MainWindow()
    win.show()
    return app.exec()
