# MotionLandmarker

Webカメラの映像から MediaPipe Holistic Landmarker で上半身のランドマークをリアルタイムに抽出し，
映像への重ね描き・動作の波形グラフ表示・録画（CSV / JSON / 動画3種）を行う macOS アプリです．

## 必要なもの

- macOS 26 以降，Xcode 26 以降
- [uv](https://docs.astral.sh/uv/)（`~/.local/bin/uv`，`/opt/homebrew/bin/uv` などに置かれていること）
- 初回起動時はネットワーク接続（Python 依存関係の取得のため）

推論は Swift ではなく Python（mediapipe 0.10 系）で行います．
MediaPipe には macOS 向けの Swift SDK が無いため，アプリが `landmarker/` を
子プロセス（サイドカー）として起動し，パイプでフレームとランドマークをやり取りします．

## 起動方法

### Xcode から

`MotionLandmarker.xcodeproj` を開き，スキーム `MotionLandmarker` を Run します．

### コマンドラインから

```bash
cd MotionLandmarker
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MotionLandmarker.xcodeproj -scheme MotionLandmarker \
  -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/MotionLandmarker.app
```

Xcode の自動署名（Apple Development 証明書）でビルドされます．
`CODE_SIGN_IDENTITY=-`（ad-hoc 署名）は付けないでください．ad-hoc 署名はビルドのたびに
アプリの識別子が変わるため，一度与えたカメラの許可が次のビルドで効かなくなります（後述）．

### 初回起動時の流れ

1. カメラの使用許可を求めるダイアログが出るので「許可」を押す
2. `landmarker/` が `~/Library/Application Support/MotionLandmarker/landmarker/` へ展開され，`uv sync` が走る（数十秒，要ネットワーク）
3. MediaPipe のモデルが読み込まれ，画面上部の表示が「MediaPipe xx fps」に変われば動作中

### カメラの許可（システム設定での操作）

ダイアログで「許可しない」を押した場合や，映像の代わりに「カメラへのアクセスが許可されていません」と表示される場合は，
次の手順で許可します．

1. Apple メニュー → **システム設定** を開く
2. 左の一覧から **プライバシーとセキュリティ** を選ぶ
3. 右側の **カメラ** をクリックする
4. 一覧の **MotionLandmarker** のスイッチをオンにする（管理者パスワードを求められることがある）
5. **アプリをいったん終了して起動し直す**（許可は起動時にしか読み込まれない）

アプリ内の「システム設定のカメラ項目を開く」ボタンを押すと，3 の画面が直接開きます．

#### スイッチがオンなのに拒否される場合

macOS はカメラの許可を「バンドル ID ＋ アプリの署名」の組で記録します．
署名が変わったアプリ（ad-hoc 署名で再ビルドしたもの，別の Mac でビルドしたもの，
GitHub Releases からダウンロードした版を更新したもの）は，設定画面ではオンに見えても
別のアプリとして扱われ，拒否されます．この場合はターミナルで許可の記録を消してから起動し直します．

```bash
tccutil reset Camera Theta-Akihisa.MotionLandmarker
open /Applications/MotionLandmarker.app   # 起動し直すとダイアログが再度出る
```

Xcode の自動署名でビルドしている限り，署名は安定しているのでこの操作は不要です．

`landmarker.py` / `pyproject.toml` / `uv.lock` を変更すると，次回起動時に展開先が自動で更新されます．

## 画面

| 場所 | 内容 |
|------|------|
| 上段 | カメラ映像＋ランドマーク．顔 / 体（pose）/ 左手 / 右手の表示チェックボックスと，カメラ選択のプルダウン |
| ボタン列 | Record（⌘R）/ Switch（次のカメラへ）/ Play（直前の overlay 動画を再生）/ Reveal（保存先を Finder で開く）/ 保存先…（出力フォルダを選ぶ） |
| 下段 | 波形グラフ．「上半身」「手腕」の切り替えボタンでモードを選び，グラフ単位・系列単位のチェックボックスで表示 / 非表示を切り替え |

波形のモード：

| モード | グラフ |
|------|------|
| 上半身 | 頭の向き（ヨー・ピッチ・ロール），体の向き（肩のヨー・ロール），手首 x，手首 y，手首 速度 |
| 手腕 | 前腕の角度（肘→手首の向き），手の向き（手首→中指付け根の向き），手の開き（指先〜手首の距離を手のひら長で割った値），手首 速度 |

手腕モードの角度は画面上の向きで，右向きが 0，上向きが +90 です．
手の開きは握った状態でおよそ 1，開いた状態でおよそ 2 になります．左右はいつも同じ色（左が緑，右がオレンジ）です．

角度はランドマークの正規化座標から求めた推定値（度）です．
検出されなかったフレームでは値を出さず，その区間の線は途切れます．
表示のチェックボックスは録画内容には影響しません（録画時は常に全部位を描画します）．

## 録画

Record で保存先フォルダに書き出します．既定は `~/Documents/MotionLandmarker/results_data/` で，
「保存先…」ボタンで任意のフォルダに変更できます（設定は次回起動時も保持されます．
ボタン列の下に現在の保存先が表示され，「既定に戻す」で元に戻せます）．
ファイル名は `live_{日時}` で，配置と列構成は video2landmark のバッチ処理と同じです．

```
results_data/
├── csv/live_20260903_120000/live_20260903_120000_{face,hand,pose}.csv
├── json/live_20260903_120000/live_20260903_120000_{face,hand,pose}.json
├── video_raw/live_20260903_120000_raw.mp4             （生映像）
├── video_overlay/live_20260903_120000_overlay.mp4     （映像＋ランドマーク）
└── video_skeleton/live_20260903_120000_skeleton.mp4   （ランドマークのみ）
```

3 本の動画はどれも推論を通ったフレームだけで構成され，フレームと時刻は互いに一致します．
このため動画のフレーム数と CSV / JSON の行数も通常一致します．
録画中にアプリを終了した場合も，書き出しが終わってから終了します．

動画では pose の手首（15, 16）とその先（17〜22）を描かず，前腕は pose の肘から hand の手首へ引きます．
hand が検出されなかった側は前腕を描きません（video2landmark と同じ規則）．
CSV / JSON には pose の 33 点すべてが記録されます．

推論には幅 640px に縮小した JPEG を渡しているため，同じ映像をバッチ処理した結果とはわずかに異なります．

## 動画ファイルで検証する

カメラを使わずに，推論→描画→CSV / JSON / 動画3種の書き出しまでをアプリ本体と同じ経路で確認できます．

```bash
build/Build/Products/Debug/MotionLandmarker.app/Contents/MacOS/MotionLandmarker \
  --check <動画ファイル> "$PWD/landmarker" /tmp/sg_check
```

送受信したフレーム数，検出数，出力先が表示されます．
第2引数はサイドカーのディレクトリ（リポジトリ内の `landmarker/` を直接使う），第3引数は出力先です．

## ディレクトリ

| パス | 内容 |
|------|------|
| `MotionLandmarker/` | Swift ソース |
| `landmarker/` | Python サイドカー（`landmarker.py`，`pyproject.toml`，`uv.lock`，`models/`） |
| `landmarker/models/holistic_landmarker.task` | MediaPipe のモデル．無ければ初回起動時にダウンロードされる |
