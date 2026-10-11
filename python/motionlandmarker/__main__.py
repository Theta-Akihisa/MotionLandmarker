"""コマンドライン入口．

  motionlandmarker                      GUI を起動
  motionlandmarker import <動画> [出力先] [--multi]
  motionlandmarker doctor               環境（OS，各ライブラリ，カメラ，コーデック）を表示
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def cmd_import(args) -> int:
    from .detectors import MODE_MULTI, MODE_SINGLE
    from .importer import import_video
    from .pipeline import Pipeline
    out = Path(args.output) if args.output else Path.cwd() / "results_data"
    pipe = Pipeline(MODE_MULTI if args.multi else MODE_SINGLE)
    last = [0]

    def progress(done, total):
        if done - last[0] >= 50 or done == total:
            last[0] = done
            print(f"{done}/{total}", flush=True)

    try:
        r = import_video(Path(args.video), out, pipe, multi_person=args.multi, progress=progress)
    finally:
        pipe.close()
    print(f"imported stem={r.stem} frames={r.frame_count} skipped={r.skipped_video_frames}")
    for p in r.output_paths:
        print("output:", p)
    return 0


def cmd_doctor(args) -> int:
    import platform
    print("platform:", platform.platform(), platform.machine())
    print("python:", sys.version.split()[0])
    for name in ("numpy", "cv2", "mediapipe", "PySide6", "pyqtgraph"):
        try:
            m = __import__(name)
            print(f"{name}: {getattr(m, '__version__', '?')}")
        except Exception as e:
            print(f"{name}: NOT AVAILABLE ({e})")
    try:
        import ultralytics, torch
        print(f"ultralytics: {ultralytics.__version__} torch: {torch.__version__} "
              f"(mps={torch.backends.mps.is_available()}, cuda={torch.cuda.is_available()})")
    except Exception:
        print("ultralytics: not installed（複数人モードは使えません．uv sync --extra multi）")
    from .detectors import models_dir
    print("models dir:", models_dir())
    import cv2, tempfile, os
    from .recorder import open_writer
    with tempfile.TemporaryDirectory() as d:
        for codec in ("avc1", "mp4v"):
            p = Path(d) / f"t_{codec}.mp4"
            try:
                from .recorder import _suppress_stderr
                with _suppress_stderr():
                    w = cv2.VideoWriter(str(p), cv2.VideoWriter_fourcc(*codec), 30, (64, 64))
                    ok = w.isOpened()
                w.release()
            except Exception:
                ok = False
            print(f"codec {codec}: {'OK' if ok else 'unavailable'}")
    try:
        from PySide6.QtMultimedia import QMediaDevices
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance() or QCoreApplication(sys.argv)
        cams = QMediaDevices.videoInputs()
        print("cameras:", [c.description() for c in cams] or "none")
    except Exception as e:
        print("cameras: error", e)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="motionlandmarker")
    sub = parser.add_subparsers(dest="cmd")
    p_imp = sub.add_parser("import", help="動画を処理して CSV / JSON / 動画 3 種を書き出す")
    p_imp.add_argument("video")
    p_imp.add_argument("output", nargs="?")
    p_imp.add_argument("--multi", action="store_true", help="複数人モード")
    sub.add_parser("doctor", help="環境を表示")
    sub.add_parser("gui", help="GUI を起動（既定）")
    args = parser.parse_args(argv)
    if args.cmd == "import":
        return cmd_import(args)
    if args.cmd == "doctor":
        return cmd_doctor(args)
    from .gui.main_window import run
    return run()


if __name__ == "__main__":
    sys.exit(main())
