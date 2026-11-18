//
//  SelfCheck.swift
//  MotionLandmarker
//
//  `MotionLandmarker --check <動画> [サイドカーdir] [出力先]`
//  カメラの代わりに動画ファイルのフレームをアプリ本体と同じ LandmarkPipeline に流し，
//  CSV / JSON / raw / overlay / skeleton を書き出す。GUI もカメラも使わずにパイプライン全体を検証する。
//  サイドカーは指定ディレクトリ（既定は実行ファイルからみた ../../../../landmarker）を uv run で直接使う。
//  `MotionLandmarker --selftest` はサイドカーもカメラも使わず，純粋なロジック（タイルの並べ方，
//  人物番号の割り当て，people.json の読み込みと古い形式へのフォールバック）だけを確かめる。
//

import AVFoundation
import QuartzCore
import Foundation

nonisolated enum SelfCheck {
    /// 再生のタイル表示と同じ方法（AVPlayerItemVideoOutput）で，再生中・一時停止してシーク後に
    /// フレームを取り出せるかを確かめる（画面は使わない。AVPlayerLayer も付けない）
    private static func checkVideoOutput(_ url: URL) -> String {
        let player = AVPlayer(url: url)
        guard let item = player.currentItem else { return "no item" }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        func pull(for seconds: Double) -> (count: Int, last: Double) {
            var count = 0, last = -1.0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                let t = output.itemTime(forHostTime: CACurrentMediaTime())
                guard output.hasNewPixelBuffer(forItemTime: t) else { continue }
                var shown = CMTime.zero
                if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown),
                   FrameEncoder.cgImage(from: pb) != nil {
                    count += 1
                    last = shown.seconds
                }
            }
            return (count, last)
        }
        player.play()
        let playing = pull(for: 1.5)
        player.pause()
        player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let paused = pull(for: 1.0)
        return "playing frames=\(playing.count) / paused+seek(0.5s) frames=\(paused.count) at \(String(format: "%.3f", paused.last))s"
    }

    /// `--selftest [録画の動画...]`：純粋なロジックのチェック。失敗があれば 1 を返す。
    /// 動画を渡すと，その録画の people.json から復元した人物の番号・枠の有無を表示する（古い録画は「番号なし」）
    static func runLogicTests(arguments: [String] = []) -> Int32 {
        if let i = arguments.firstIndex(of: "--selftest") {
            for path in arguments.dropFirst(i + 1) {
                let url = URL(fileURLWithPath: path)
                if let t = PeopleTrack.load(forVideo: url) {
                    let shown = t.boxes.map(PersonTiles.personTileCount)
                    print("people: \(url.lastPathComponent) frames=\(t.timestamps.count) slots=\(t.slots) "
                          + "tiles(min/max)=\(shown.min() ?? 0)/\(shown.max() ?? 0) "
                          + "samples=\(t.slots.map { s in t.timelines[s]!.values[.bodyRoll]!.compactMap { $0 }.count })")
                    print("video output: \(checkVideoOutput(url))")
                } else {
                    print("people: \(url.lastPathComponent) 番号なし（従来の 1 枚表示）")
                }
            }
        }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }

        // タイルの並べ方：合計 = 1 + 人数。4 以下は横 1 列，5〜6 は 2×3（左上が全体，5 人目が右下）
        let expected: [(Int, Int)] = [(1, 1), (1, 2), (1, 3), (1, 4), (2, 3), (2, 3)]
        for n in 0...5 {
            let g = PersonTiles.grid(personCount: n)
            check(g.rows == expected[n].0 && g.columns == expected[n].1, "grid(\(n) 人) = \(g.rows)×\(g.columns)")
        }
        check(PersonTiles.grid(personCount: 9) == (2, 3), "grid(上限超え) は 2×3")
        check(PersonTiles.cell(index: 0, personCount: 5) == (0, 0), "5 人：全体映像は左上")
        check(PersonTiles.cell(index: 5, personCount: 5) == (1, 2), "5 人：5 人目は右下")
        check(PersonTiles.cell(index: 3, personCount: 3) == (0, 3), "3 人：3 人目は右端")
        check(PersonTiles.cell(index: 3, personCount: 4) == (1, 0), "4 人：3 人目は 2 行目の左")
        checkTileCrop(check)

        // 人物タイルの数は見えている番号の最大値（空いた番号の枠を残す）
        let r0 = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        check(PersonTiles.personTileCount([]) == 0, "0 人：全体映像のみ")
        check(PersonTiles.personTileCount([PersonBox(slot: 1, bbox: r0, detected: true),
                                           PersonBox(slot: 3, bbox: r0, detected: true)]) == 3,
              "1 人目と 3 人目 → 人物タイル 3 枚（2 人目は空き）")
        check(PersonTiles.grid(personCount: PersonTiles.personTileCount([PersonBox(slot: 4, bbox: r0, detected: true)])) == (2, 3),
              "4 人目だけ → 5 タイルなので 2×3")

        // 人物番号の割り当て
        let box = { (x: Double) in CGRect(x: x, y: 0.2, width: 0.1, height: 0.5) }
        var a = PersonSlotAssigner()
        check(a.assign([(10, box(0.1)), (20, box(0.5))], timestampMs: 0) == [1, 2], "新しい追跡 ID は小さい番号から")
        check(a.assign([(20, box(0.5)), (10, box(0.1))], timestampMs: 33) == [2, 1], "並びが変わっても同じ番号")
        check(a.assign([(20, box(0.5))], timestampMs: 66) == [2], "1 人消えても番号は変わらない")
        check(a.assign([(20, box(0.5)), (30, box(0.8))], timestampMs: 100) == [2, 3], "消えた人の番号は予約中で他人に渡さない")
        check(a.assign([(10, box(0.1)), (20, box(0.5)), (30, box(0.8))], timestampMs: 500) == [1, 2, 3], "戻ってきた人は元の番号")
        check(a.assign([(nil, box(0.51)), (30, box(0.8))], timestampMs: 533) == [2, 3], "追跡 ID が無い人は枠の重なりで当てる")
        check(a.assign([(40, box(0.3))], timestampMs: 5000) == [1], "予約期間を過ぎた番号は空きに戻る")
        var full = PersonSlotAssigner()
        _ = full.assign((1...5).map { (Int?($0), Optional(box(Double($0) * 0.15))) }, timestampMs: 0)
        _ = full.assign([(1, box(0.15)), (2, box(0.3)), (3, box(0.45)), (5, box(0.75))], timestampMs: 100)
        check(full.assign([(1, box(0.15)), (2, box(0.3)), (3, box(0.45)), (5, box(0.75)), (6, box(0.6))],
                          timestampMs: 200) == [1, 2, 3, 5, 4], "空きが無いときだけ最も長く見えていない番号を回す")
        var back = PersonSlotAssigner()
        _ = back.assign([(7, box(0.1))], timestampMs: 1000)
        check(back.assign([(8, box(0.1))], timestampMs: 10) == [1], "時刻が戻ったら割り当てをやり直す")

        // 保持：1 フレームの検出漏れでは枠が消えない
        var hold = PersonHold()
        _ = hold.update([(1, box(0.1)), (2, box(0.5))], timestampMs: 0)
        let held = hold.update([(1, box(0.1))], timestampMs: 33)
        check(held.map(\.slot) == [1, 2] && held[1].detected == false, "検出漏れの人は直前の枠を残す")
        check(hold.update([(1, box(0.1))], timestampMs: 2000).map(\.slot) == [1], "保持時間を過ぎたら消す")

        // people.json：番号付きの形式と古い形式
        func person(_ slot: Int?, _ x: Double) -> [String: Any] {
            var d: [String: Any] = ["pose": NSNull(), "face": NSNull(), "left": NSNull(),
                                    "right": (0..<21).map { _ in ["x": x, "y": 0.5, "z": 0.0] }]
            if let slot { d["slot"] = slot; d["bbox"] = [x, 0.2, 0.1, 0.5] }
            return d
        }
        let newRows: [[String: Any]] = [
            ["frame": 0, "timestamp_ms": 1000, "people": [person(1, 0.1), person(2, 0.5)]],
            ["frame": 1, "timestamp_ms": 1033, "people": [person(2, 0.52)]],
            ["frame": 2, "timestamp_ms": 1066, "people": [person(2, 0.54), person(3, 0.8)]],
        ]
        let oldRows: [[String: Any]] = [["frame": 0, "timestamp_ms": 0, "people": [person(nil, 0.1)]]]
        if let data = try? JSONSerialization.data(withJSONObject: newRows), let t = PeopleTrack.parse(data) {
            check(t.slots == [1, 2, 3], "people.json：出てくる番号")
            check(t.timelines.values.allSatisfy { $0.values[.rightWristX]?.count == 3 }, "人物ごとの時系列はフレーム数と同じ長さ")
            check(t.timelines[1]?.values[.rightWristX]?[1] == nil, "いないフレームは欠損")
            check(t.timelines[3]?.values[.rightWristX]?[0] == nil && t.timelines[3]?.values[.rightWristX]?[2] != nil,
                  "途中から現れた人は前を欠損で埋める")
            check(t.boxes(atVideoTime: 0.04).map(\.slot) == [1, 2], "再生位置 0.04 秒は 2 フレーム目（1 人目は保持）")
            check(t.boxes(atVideoTime: 10).map(\.slot) == [1, 2, 3], "末尾より後は最終フレーム")
        } else {
            check(false, "people.json（番号付き）を読めない")
        }
        if let data = try? JSONSerialization.data(withJSONObject: oldRows) {
            check(PeopleTrack.parse(data) == nil, "番号の無い古い people.json はタイル表示しない（nil）")
        }
        // 録画の書き出し：番号と枠があるときだけ slot / bbox を書く
        var frame = LandmarkFrame.empty(timestampMs: 0)
        frame.pose = (0..<LandmarkFrame.poseCount).map { _ in Landmark(x: 0.5, y: 0.5, z: 0) }
        frame.slot = 2
        frame.bbox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        var rows: [[String: Any]] = []
        LandmarkJSON.appendPeople(frameIndex: 0, frame: frame, into: &rows)
        let p0 = (rows.first?["people"] as? [[String: Any]])?.first
        check(p0?["slot"] as? Int == 2 && (p0?["bbox"] as? [Double])?.count == 4, "people.json に slot / bbox を書く")

        print(failures == 0 ? "all logic checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    /// 人物タイルの切り出し：枠の形・大きさによらず画像の大きさが一定か，画像の外にはみ出した部分が
    /// クリップされず（縦横比を保ち）黒で埋まるか。元画像は上半分が赤・下半分が緑（上下の向きも確かめる）
    private static func checkTileCrop(_ check: (Bool, String) -> Void) {
        let size = CGSize(width: 640, height: 480)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let src = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else {
            check(false, "タイル検査用の画像を作れない")
            return
        }
        src.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        src.fill(CGRect(x: 0, y: 0, width: 640, height: 240))     // 下半分（CoreGraphics は左下原点）
        src.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        src.fill(CGRect(x: 0, y: 240, width: 640, height: 240))   // 上半分
        guard let image = src.makeImage() else { return }

        /// タイル画像の (fx, fy)（左上原点の割合）の画素 (r, g, b)
        func pixel(_ img: CGImage, _ fx: CGFloat, _ fy: CGFloat) -> (Int, Int, Int)? {
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ok: Bool = buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            let x = min(w - 1, Int(fx * CGFloat(w))), y = min(h - 1, Int(fy * CGFloat(h)))
            let i = (y * w + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        func isBlack(_ p: (Int, Int, Int)?) -> Bool { p.map { $0.0 < 16 && $0.1 < 16 && $0.2 < 16 } ?? false }
        func isRed(_ p: (Int, Int, Int)?) -> Bool { p.map { $0.0 > 200 && $0.1 < 50 && $0.2 < 50 } ?? false }

        // 形・大きさの違う枠（縦長・横長・小・大・画像からはみ出す）を同じ縦横比で切り出す
        let boxes = [CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.6), CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.15),
                     CGRect(x: 0.45, y: 0.45, width: 0.03, height: 0.05), CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
                     CGRect(x: 0.85, y: 0.3, width: 0.2, height: 0.4)]
        for aspect in [CGFloat(0.75), 1.6] {
            let expected = PersonTiles.tileSize(aspect: aspect)
            var sizes = Set<String>()
            var shapeOK = true
            for b in boxes {
                guard let r = PersonTiles.cropRect(for: b, imageSize: size, aspect: aspect) else { shapeOK = false; continue }
                shapeOK = shapeOK && abs(r.width / r.height - aspect) < 1e-6
                    && abs(r.midX - b.midX * size.width) < 1e-6 && abs(r.midY - b.midY * size.height) < 1e-6
                    && r.width >= b.width * size.width && r.height >= b.height * size.height
                for bg in [image, nil] {
                    let t = SkeletonRenderer.personTile(nil, background: bg, crop: r, fullSize: size, outputSize: expected)
                    sizes.insert(t.map { "\($0.width)x\($0.height)" } ?? "nil")
                }
            }
            check(shapeOK, "cropRect は枠の中心のまま縦横比 \(aspect) に広げる（枠を含む）")
            check(sizes == ["\(Int(expected.width))x\(PersonTiles.tileHeight)"],
                  "枠の形・大きさによらずタイル画像は \(Int(expected.width))×\(PersonTiles.tileHeight)（得られた大きさ: \(sizes.sorted())）")
        }
        check(PersonTiles.cellAspects(for: CGSize(width: 1000, height: 300))[1].map { abs($0 - (498.0 / 300)) < 1e-6 } ?? false,
              "マスの縦横比：横 1 列 2 タイル（間隔 4）")
        check(PersonTiles.cellAspects(for: CGSize(width: 1000, height: 300))[5].map { abs($0 - (992.0 / 3 / 148)) < 1e-6 } ?? false,
              "マスの縦横比：5 人は 2×3")

        // 右端からはみ出す枠：クリップせず縦横比を保ち，はみ出した部分は黒
        let right = CGRect(x: 0.85, y: 0.3, width: 0.2, height: 0.4)
        if let r = PersonTiles.cropRect(for: right, imageSize: size, aspect: 0.75),
           let t = SkeletonRenderer.personTile(nil, background: image, crop: r, fullSize: size,
                                               outputSize: PersonTiles.tileSize(aspect: 0.75)) {
            check(r.maxX > size.width && abs(r.width / r.height - 0.75) < 1e-6, "右にはみ出す枠：切り出し範囲はクリップしない")
            check(isBlack(pixel(t, 0.95, 0.4)) && isRed(pixel(t, 0.3, 0.4)), "右にはみ出す枠：外は黒，内側は元画像")
        } else {
            check(false, "右にはみ出す枠のタイルを作れない")
        }
        // 上端からはみ出す横長の枠：上が黒，下に元画像（上半分の赤）が来る（上下が逆になっていない）
        let top = CGRect(x: 0.3, y: 0.0, width: 0.4, height: 0.2)
        if let r = PersonTiles.cropRect(for: top, imageSize: size, aspect: 0.75),
           let t = SkeletonRenderer.personTile(nil, background: image, crop: r, fullSize: size,
                                               outputSize: PersonTiles.tileSize(aspect: 0.75)) {
            check(r.minY < 0 && abs(r.width / r.height - 0.75) < 1e-6, "上にはみ出す枠：切り出し範囲はクリップしない")
            check(isBlack(pixel(t, 0.5, 0.1)) && isRed(pixel(t, 0.5, 0.8)), "上にはみ出す枠：上は黒，下は元画像の上半分")
        } else {
            check(false, "上にはみ出す枠のタイルを作れない")
        }
        // skeleton 表示（背景なし）もはみ出しの有無によらず同じ大きさ
        if let r = PersonTiles.cropRect(for: top, imageSize: size, aspect: 0.75),
           let t = SkeletonRenderer.personTile(nil, background: nil, crop: r, fullSize: size,
                                               outputSize: PersonTiles.tileSize(aspect: 0.75)) {
            check(t.height == PersonTiles.tileHeight, "skeleton のスケッチ背景も固定の高さ")
        }
        check(PersonTiles.cropRect(for: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001), imageSize: size, aspect: 0.75) == nil,
              "小さすぎる枠は切り出さない")
    }

    /// `--import <動画> [サイドカーdir] [出力先]`：アプリの「動画を処理…」と同じ VideoImporter を GUI 無しで動かす
    static func runImport(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--import"), i + 1 < arguments.count else { return 2 }
        let videoURL = URL(fileURLWithPath: arguments[i + 1])
        let sidecar = URL(fileURLWithPath: i + 2 < arguments.count ? arguments[i + 2]
                          : FileManager.default.currentDirectoryPath + "/landmarker")
        let outputRoot = URL(fileURLWithPath: i + 3 < arguments.count ? arguments[i + 3]
                             : FileManager.default.temporaryDirectory.appendingPathComponent("MotionLandmarker_import").path)
        guard let uv = SidecarBootstrap.locateUV() else { print("uv not found"); return 1 }
        let client = LandmarkerClient()
        let ready = DispatchSemaphore(value: 0)
        client.onReady = { ready.signal() }
        client.onExit = { code, log in if code != 0 { print("sidecar exited \(code)\n\(log)") } }
        let pipeline = LandmarkPipeline(client: client)
        // アプリと同じ sync を先に行う（素の uv sync で壊れた cv2 もここで直る）
        do { try SidecarBootstrap.sync(uv: uv, project: sidecar) } catch { print("sidecar sync failed: \(error)"); return 1 }
        do { try client.start(uv: uv, project: sidecar) } catch { print("sidecar start failed: \(error)"); return 1 }
        guard ready.wait(timeout: .now() + 120) == .success else { print("sidecar did not become ready"); return 1 }
        // アプリ内と同じ条件にするため，環境変数 ML_FAKE_CAMERA に動画を指定すると
        // 別スレッドからカメラ相当のフレームを流し続ける（処理開始まで 1 秒流し，処理中は捨てられる）
        var fakeCameraRunning = true
        if let camPath = ProcessInfo.processInfo.environment["ML_FAKE_CAMERA"] {
            Thread.detachNewThread {
                let asset = AVURLAsset(url: URL(fileURLWithPath: camPath))
                guard let track = asset.tracks(withMediaType: .video).first,
                      let reader = try? AVAssetReader(asset: asset) else { return }
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(out); reader.startReading()
                var ms = 0
                while fakeCameraRunning, let sb = out.copyNextSampleBuffer() {
                    if let pb = CMSampleBufferGetImageBuffer(sb) { pipeline.handleCameraFrame(pb, ms) }
                    ms += 33; usleep(33_000)
                }
            }
            sleep(1)
        }
        pipeline.setCameraPaused(true)
        defer { fakeCameraRunning = false }
        // 環境変数 ML_PERSON_MODE=2 で複数人モードを検証する
        let multi = ProcessInfo.processInfo.environment["ML_PERSON_MODE"] == "2"
        if multi {
            let switched = DispatchSemaphore(value: 0)
            client.onMode = { m in print("mode -> \(m)"); switched.signal() }
            pipeline.setPersonMode(2)
            guard switched.wait(timeout: .now() + 300) == .success else { print("mode switch timed out"); return 1 }
        }
        do {
            let r = try VideoImporter.run(videoURL: videoURL, outputRoot: outputRoot, pipeline: pipeline,
                                          multiPerson: multi,
                                          progress: { done, total in if done % 50 == 0 { print("\(done)/\(total)") } },
                                          isCancelled: { false })
            print("imported stem=\(r.stem) frames=\(r.frames) skipped=\(r.skippedVideoFrames) overlay=\(r.overlayURL.path)")
        } catch {
            print("import failed: \(error.localizedDescription)"); client.stop(); return 1
        }
        client.stop()
        return 0
    }

    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--check"), i + 1 < arguments.count else { return 2 }
        let videoPath = arguments[i + 1]
        let sidecar = URL(fileURLWithPath: i + 2 < arguments.count ? arguments[i + 2]
                          : FileManager.default.currentDirectoryPath + "/landmarker")
        let outputRoot = URL(fileURLWithPath: i + 3 < arguments.count ? arguments[i + 3]
                             : FileManager.default.temporaryDirectory.appendingPathComponent("MotionLandmarker_check").path)
        guard let uv = SidecarBootstrap.locateUV() else { print("uv not found"); return 1 }

        let client = LandmarkerClient()
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        client.onReady = { ready.signal() }
        client.onExit = { code, log in if code != 0 { print("sidecar exited \(code)\n\(log)") } }
        let pipeline = LandmarkPipeline(client: client)
        let stats = Stats()
        pipeline.onFrame = { _, frame, _, _, recorded in
            stats.add(frame, recorded: recorded)
            done.signal()
        }
        // アプリと同じ sync を先に行う（素の uv sync で壊れた cv2 もここで直る）
        do { try SidecarBootstrap.sync(uv: uv, project: sidecar) } catch { print("sidecar sync failed: \(error)"); return 1 }
        do { try client.start(uv: uv, project: sidecar) } catch { print("sidecar start failed: \(error)"); return 1 }
        guard ready.wait(timeout: .now() + 120) == .success else { print("sidecar did not become ready"); return 1 }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { print("cannot open video: \(videoPath)"); return 1 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()

        let stem = "check_" + URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        var sent = 0
        let start = Date()
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let ms = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1000).rounded())
            pipeline.waitUntilIdle()
            pipeline.handleCameraFrame(pb, ms)
            sent += 1
            guard done.wait(timeout: .now() + 30) == .success else { print("timeout at frame \(sent)"); return 1 }
            if sent == 1 {
                // 録画サイズは最初のフレームから決まる（カメラと同じ流れ）
                do { try pipeline.startRecording(outputRoot: outputRoot, stem: stem) } catch {
                    print("recorder failed: \(error)"); return 1
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        let finished = DispatchSemaphore(value: 0)
        let result = ResultBox()
        pipeline.stopRecording { r, e in result.set(r, e); finished.signal() }
        finished.wait()
        client.stop()

        let (recorder, error) = result.get()
        let s = stats.snapshot()
        print("frames sent=\(sent) received=\(s.received) recorded=\(s.recorded) skipped_video=\(recorder?.skippedVideoFrames ?? 0) fps=\(String(format: "%.1f", Double(sent) / elapsed))")
        print("detected face=\(s.face) left=\(s.left) right=\(s.right) pose=\(s.pose)")
        if let error { print("finish error: \(error)"); return 1 }
        if let r = recorder {
            for u in [r.csvDirectory, r.jsonDirectory, r.rawURL, r.overlayURL, r.skeletonURL] { print("output: \(u.path)") }
        }
        return sent == s.received && sent > 0 ? 0 : 1
    }

    private final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var received = 0, recorded = 0, face = 0, left = 0, right = 0, pose = 0
        func add(_ f: LandmarkFrame, recorded r: Int) {
            lock.lock(); defer { lock.unlock() }
            received += 1; recorded = r
            if f.face.count == LandmarkFrame.faceCount { face += 1 }
            if f.leftHand.count == LandmarkFrame.handCount { left += 1 }
            if f.rightHand.count == LandmarkFrame.handCount { right += 1 }
            if f.pose.count == LandmarkFrame.poseCount { pose += 1 }
        }
        func snapshot() -> (received: Int, recorded: Int, face: Int, left: Int, right: Int, pose: Int) {
            lock.lock(); defer { lock.unlock() }
            return (received, recorded, face, left, right, pose)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (LandmarkRecorder?, Error?) = (nil, nil)
        func set(_ r: LandmarkRecorder?, _ e: Error?) { lock.lock(); value = (r, e); lock.unlock() }
        func get() -> (LandmarkRecorder?, Error?) { lock.lock(); defer { lock.unlock() }; return value }
    }
}
