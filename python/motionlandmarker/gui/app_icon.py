"""アプリのアイコン（Swift 版と同じ図柄）．元データは リポジトリの design/icon/．"""
from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtGui import QIcon

RESOURCES = Path(__file__).resolve().parent.parent / "resources"
APP_USER_MODEL_ID = "Theta-Akihisa.MotionLandmarker"


def app_icon() -> QIcon:
    """macOS は角丸と影のある macOS 用の図柄（1024 px の PNG），それ以外は余白の少ない図柄（.ico）．"""
    name = "MotionLandmarker.png" if sys.platform == "darwin" else "MotionLandmarker.ico"
    return QIcon(str(RESOURCES / name))


def set_windows_app_id() -> None:
    """Windows のタスクバーに python.exe ではなくこのアプリのアイコンを出すため，
    QApplication を作る前に AppUserModelID を設定する．"""
    if sys.platform != "win32":
        return
    try:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(APP_USER_MODEL_ID)
    except Exception:
        pass
