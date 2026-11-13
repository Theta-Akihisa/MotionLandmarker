# MotionLandmarker（Python 単体版）

Swift 版と同じ機能を Python だけで実装したもので，**macOS と Windows** で動きます．
Web カメラの映像から MediaPipe Holistic Landmarker で上半身のランドマークをリアルタイムに抽出し，
映像への重ね描き・動作の波形グラフ表示・録画（CSV / JSON / 動画3種）・録画の再生・動画ファイルの処理を行います．

出力の形式（CSV / JSON / metrics CSV / 動画3種 / people.json）は Swift 版と同じで，互いの録画を再生できます．

## 必要なもの

- Python 3.12（mediapipe 0.10 系の対応範囲）と [uv](https://docs.astral.sh/uv/)
- Web カメラ
- 初回起動時はネットワーク接続（MediaPipe のモデル約 14 MB を自動でダウンロードします）

mediapipe は Swift 版のサイドカーと同じ 0.10 系に固定しています（Mac と Windows で数値を揃えるため）．

## セットアップと起動

```bash
cd MotionLandmarker/python
uv sync
uv run motionlandmarker
```

Windows では PowerShell で同じコマンドを実行します．初回は `uv sync` が Python 3.12 と依存関係（PySide6，mediapipe，OpenCV など）を取得します．

### まず環境を確認する

```bash
uv run motionlandmarker doctor
```

OS，各ライブラリの版，モデルの置き場所，使える動画コーデック（avc1 / mp4v），認識しているカメラの一覧を表示します．
Windows で問題が起きたときは，最初にこの出力を確認してください．

### 動画ファイルを GUI 無しで処理する

```bash
uv run motionlandmarker import <動画> [出力先]
```

カメラと同じパイプラインで全フレームを処理し，出力先（既定はカレントディレクトリの `results_data/`）に書き出します．

## 画面

| 場所 | 内容 |
|------|------|
| 上部バー | 表示（生映像 / skeleton / overlay / 非表示），顔 / 体 / 左手 / 右手のチェックボックス，ミラー（表示だけ左右反転），推論の fps，人数（1人 / 複数人），カメラ選択 |
| 映像 | カメラ映像＋ランドマーク．下の境目を上下にドラッグして高さを変えられる |
| 再生バー（再生中のみ） | 1 フレーム戻る / 再生・一時停止（スペース）/ 1 フレーム進む，現在時刻と長さ，シークバー |
| ボタン列 | Record（Ctrl+R / ⌘R）/ Play（最新の録画を再生，もう一度押すと Live に戻る）/ 選んで再生… / Reveal（保存先を開く）/ 動画を処理… / 保存先… |
| 下段 | 波形グラフ．「上半身 / 手腕」の切り替え，グラフ単位・系列単位のチェックボックス．左の列との境目を左右にドラッグすると横幅を変えられる |

- 画面の拡大 / 縮小：Ctrl++ / Ctrl+-（macOS は ⌘），Ctrl+0 で既定に戻す
- 再生中はカメラの取り込みを止めます（推論は待機状態になります）．Live に戻すと再開します
- 再生中はグラフの横軸が録画全体になり，赤い線がシークバーと同じ位置を動きます．グラフ上でホイールを回すとカーソル位置を中心にズーム，ドラッグで移動，「全体」で戻ります
- 設定（表示，人数，保存先，ミラー，画面サイズ，分割位置）は次回起動時も保持されます

## 録画

既定の保存先は `~/Documents/MotionLandmarker/results_data/` で，「保存先…」で変えられます．

```
results_data/
├── csv/live_20260903_120000/live_20260903_120000_{face,hand,pose,metrics}.csv
├── json/live_20260903_120000/live_20260903_120000_{face,hand,pose}.json（複数人は _people.json も）
├── video_raw/live_20260903_120000_raw.mp4
├── video_overlay/live_20260903_120000_overlay.mp4
└── video_skeleton/live_20260903_120000_skeleton.mp4
```

形式の詳細（列の構成，描画規則，指標の意味）は上位フォルダの README を参照してください．Swift 版と同じです．
動画は avc1（H.264）が使えなければ mp4v で書きます（Windows では通常 mp4v）．

ライブ録画の mp4 は固定フレームレート（録画開始時の実測の推論レート）で書くため，再生時間はおおよその値です．
正確な時刻は CSV の `timestamp_ms` にあり，アプリ内の再生はこちらを使って動画と波形を同期します
（動画のフレーム番号と CSV の行番号は一致します）．

## 複数人モード（任意）

YOLO（Ultralytics）で人物の枠を検出・追跡し，人物ごとに切り出して Holistic を適用します．
Ultralytics と PyTorch が必要で（約 1 GB），**AGPL-3.0 ライセンス**です．

```bash
uv sync --extra multi
```

YOLO の重み（yolo11n.pt，約 5 MB）は初回に自動でダウンロードされます．GPU は macOS では MPS，Windows では CUDA があれば使います．
既知の制約（人同士の重なり，中央の人の入れ替わりなど）は上位フォルダの README と同じです．

## Windows での注意

- Swift 版の録画（macOS）を Python 版で再生できることは確認済みです．Python 版の録画（mp4v）を Swift 版で再生することは未確認です
- 開発・検証は macOS で行っています．Windows ではカメラの取得（Qt Multimedia），コーデック（通常 mp4v），高 DPI 表示が未検証です．まず `doctor` と `import` を試してください
- カメラの許可は Windows の「設定 > プライバシーとセキュリティ > カメラ」で，デスクトップアプリに許可されている必要があります
- `uv sync` が失敗する場合は，Python 3.12 が取得できているか（`uv python list`）とネットワーク（プロキシ）を確認してください

## 構成

| ファイル | 内容 |
|------|------|
| `motionlandmarker/detectors.py` | MediaPipe（1人）/ YOLO＋Holistic（複数人）の検出．入力サイズ変更時の作り直し |
| `motionlandmarker/metrics.py` | グラフ用の指標（頭・体の向き，手首，前腕，手の向き・開き）とモード・グラフの定義 |
| `motionlandmarker/renderer.py` | ランドマークの描画（色，前腕の規則，複数人の半透明） |
| `motionlandmarker/recorder.py` | CSV / JSON / 動画3種の書き出し |
| `motionlandmarker/timeline.py` | 再生時に波形を出すための metrics CSV の読み込み（無ければ pose / face / hand から計算） |
| `motionlandmarker/pipeline.py` | 検出 → 指標 → 描画 → 録画の流れ |
| `motionlandmarker/importer.py` | 動画ファイルの処理 |
| `motionlandmarker/gui/` | PySide6 の GUI（カメラ，ワーカー，グラフ，映像表示，メインウィンドウ） |
| `motionlandmarker/resources/` | アプリのアイコン（Swift 版と同じ図柄．macOS は `.png`，Windows は `.ico`．PyInstaller の `--icon` にも使える） |
