//
//  PersonTiles.swift
//  MotionLandmarker
//
//  複数人モードのタイル表示に使う純粋なロジック：
//    - 追跡 ID → 人物番号（1 人目，2 人目…）の割り当て（PersonSlotAssigner）
//    - 1 フレームの検出漏れでタイルの並びががたつかないようにする保持（PersonHold）
//    - タイルの並べ方（PersonTiles.grid）と人物タイルの切り出し範囲（PersonTiles.cropRect）
//    - 録画の {stem}_people.json から，人物ごとの枠と指標の時系列を復元する（PeopleTrack）
//  画面（ContentView）・パイプライン（LandmarkPipeline）・SelfCheck から使う。
//

import CoreGraphics
import Foundation

/// 1 フレームに出す人物の枠
nonisolated struct PersonBox: Sendable, Equatable, Identifiable {
    /// 人物番号（1 始まり）
    let slot: Int
    /// 人物の枠（元画像に対する正規化 x, y, w, h）
    let bbox: CGRect
    /// このフレームで検出されたか（false は PersonHold が直前の枠を残しているだけ）
    let detected: Bool
    var id: Int { slot }
}

nonisolated enum PersonTiles {
    /// 複数人モードで扱う最大人数（サイドカーの MAX_PEOPLE と同じ）
    static let maxPeople = 5

    /// 人物タイルの数：そのフレームで見えている人物番号の最大値。いない人を詰めず，空いた番号の枠を残す
    /// （例：1 人目と 3 人目だけ → 全体，1 人目，2 人目（空き），3 人目）
    static func personTileCount(_ boxes: [PersonBox]) -> Int {
        min(boxes.map(\.slot).max() ?? 0, maxPeople)
    }

    /// 人物タイルの数 → タイルの行数・列数。合計タイル数は 1（全体映像）+ 人物タイルの数。
    /// 4 タイル以下は横 1 列，5〜6 タイルは 2×3。
    static func grid(personCount: Int) -> (rows: Int, columns: Int) {
        let tiles = 1 + min(max(personCount, 0), maxPeople)
        return tiles <= 4 ? (1, tiles) : (2, 3)
    }

    /// `index` 番目のタイル（0 が全体映像，n が n 人目）の行・列。左上から行優先で並べる
    static func cell(index: Int, personCount: Int) -> (row: Int, column: Int) {
        let g = grid(personCount: personCount)
        return (index / g.columns, index % g.columns)
    }

    /// 人物の枠の周りに足す余白（枠の幅・高さに対する割合．各辺）
    static let tileMargin: CGFloat = 0.08
    /// 人物タイル画像の高さ（固定．幅は縦横比から決まる）。skeleton 表示のスケッチ背景も同じ大きさ
    static let tileHeight = 360
    /// 表示のマスの縦横比（幅 / 高さ）が分からないときの既定値
    static let defaultAspect: CGFloat = 0.75
    /// タイルの間隔（表示側と縦横比の計算で共通）
    static let tileSpacing: CGFloat = 4

    /// 映像エリアの大きさ → 人物タイルの数（1〜maxPeople）ごとのマスの縦横比（幅 / 高さ）。
    /// 人物タイルの切り出しをこれに合わせると，タイルの映像がマスいっぱいに収まり，枠の形で大きさが揺れない
    static func cellAspects(for area: CGSize) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        for n in 1...maxPeople {
            let g = grid(personCount: n)
            let cw = (area.width - tileSpacing * CGFloat(g.columns - 1)) / CGFloat(g.columns)
            let ch = (area.height - tileSpacing * CGFloat(g.rows - 1)) / CGFloat(g.rows)
            out[n] = cw > 0 && ch > 0 ? min(max(cw / ch, 0.2), 5) : defaultAspect
        }
        return out
    }

    /// 縦横比 → 人物タイル画像の大きさ（画素）。高さは tileHeight で固定
    static func tileSize(aspect: CGFloat) -> CGSize {
        CGSize(width: max(1, (CGFloat(tileHeight) * aspect).rounded()), height: CGFloat(tileHeight))
    }

    /// 人物タイルに切り出す範囲（画素，左上原点）。正規化した枠に各辺 tileMargin の余白を足し，
    /// 中心を保ったまま縦横比 `aspect`（幅 / 高さ）に広げる（短い方を伸ばす）。
    /// 画像の外にはみ出す部分はそのまま返す（クリップすると縦横比が崩れるので，描く側で黒く塗る）。小さすぎれば nil
    static func cropRect(for bbox: CGRect, imageSize: CGSize, aspect: CGFloat) -> CGRect? {
        var cw = bbox.width * (1 + 2 * tileMargin) * imageSize.width
        var ch = bbox.height * (1 + 2 * tileMargin) * imageSize.height
        guard cw >= 4, ch >= 4, aspect > 0 else { return nil }
        if cw / ch < aspect { cw = ch * aspect } else { ch = cw / aspect }
        let cx = bbox.midX * imageSize.width, cy = bbox.midY * imageSize.height
        return CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
    }

    /// 2 つの枠の IoU（重なり / 和集合）
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}

/// 追跡 ID → 人物番号（1〜maxPeople）の割り当て。フレームをまたいで番号を安定させる。
///
/// 番号の決め方：
///  1. すでに番号を持つ追跡 ID は，同じ番号を使い続ける。
///  2. 新しい追跡 ID には，空いている番号のうち最小のものを割り当てる。
///  3. 人が画面から消えても（その追跡 ID が来なくなっても），番号は `holdMs` のあいだ元の追跡 ID のために
///     予約しておき，他の人には渡さない（その間に同じ追跡 ID が戻れば同じ番号に戻る）。
///  4. 予約期間を過ぎた番号は空きに戻る。空きが無いとき（5 つすべてが使用中・予約中）だけ，
///     このフレームに写っていない番号のうち最も長く見えていないものを新しい追跡 ID に回す。
///  5. 追跡 ID が無い人（サイドカーが追跡に失敗したフレーム）は，このフレームでまだ使われていない番号のうち
///     直前の枠との IoU が最も大きいもの（`minIoU` 以上）に当てる。当てはまらなければ番号を付けない。
///  入力の時刻が戻ったとき（入力源の切り替え）は割り当てをすべて捨てる。
nonisolated struct PersonSlotAssigner: Sendable {
    var holdMs = 3000
    var minIoU: CGFloat = 0.3
    private struct Owner {
        var trackID: Int
        var lastSeenMs: Int
        var bbox: CGRect?
    }
    /// 人物番号 → 持ち主
    private var owners: [Int: Owner] = [:]
    private var lastMs: Int?

    init() {}

    mutating func reset() {
        owners.removeAll()
        lastMs = nil
    }

    /// 1 フレーム分の人物（追跡 ID と枠）に番号を割り当てる。戻り値は入力と同じ順（番号が無ければ nil）
    mutating func assign(_ people: [(trackID: Int?, bbox: CGRect?)], timestampMs: Int) -> [Int?] {
        if let lastMs, timestampMs < lastMs { reset() }
        lastMs = timestampMs
        // 予約期間を過ぎた番号を空きに戻す
        for (slot, o) in owners where timestampMs - o.lastSeenMs > holdMs { owners[slot] = nil }

        var result = [Int?](repeating: nil, count: people.count)
        var used = Set<Int>()
        // 1. 番号を持つ追跡 ID
        for (i, p) in people.enumerated() {
            guard let id = p.trackID,
                  let slot = owners.first(where: { $0.value.trackID == id })?.key,
                  !used.contains(slot) else { continue }
            result[i] = slot
            used.insert(slot)
        }
        // 2・4. 新しい追跡 ID
        for (i, p) in people.enumerated() where result[i] == nil {
            guard let id = p.trackID, !owners.values.contains(where: { $0.trackID == id }) else { continue }
            var slot = (1...PersonTiles.maxPeople).first { owners[$0] == nil }
            if slot == nil {
                slot = owners.filter { !used.contains($0.key) }.min { $0.value.lastSeenMs < $1.value.lastSeenMs }?.key
            }
            guard let slot else { continue }
            owners[slot] = Owner(trackID: id, lastSeenMs: timestampMs, bbox: p.bbox)
            result[i] = slot
            used.insert(slot)
        }
        // 5. 追跡 ID の無い人は直前の枠との重なりで当てる
        for (i, p) in people.enumerated() where result[i] == nil && p.trackID == nil {
            guard let box = p.bbox else { continue }
            let best = owners.filter { !used.contains($0.key) }
                .compactMap { slot, o in o.bbox.map { (slot, PersonTiles.iou($0, box)) } }
                .max { $0.1 < $1.1 }
            guard let best, best.1 >= minIoU else { continue }
            result[i] = best.0
            used.insert(best.0)
        }
        for (i, slot) in result.enumerated() {
            guard let slot else { continue }
            owners[slot]?.lastSeenMs = timestampMs
            if let b = people[i].bbox { owners[slot]?.bbox = b }
        }
        return result
    }
}

/// 見えなくなった人物の枠を `holdMs` のあいだ残し，1 フレームの検出漏れでタイルの数・並びが
/// がたつかないようにする。ライブ（LandmarkPipeline）と録画の再生（PeopleTrack）で同じ規則を使う。
nonisolated struct PersonHold: Sendable {
    var holdMs = 1000
    private var last: [Int: (bbox: CGRect, ms: Int)] = [:]
    private var lastMs: Int?

    init() {}

    mutating func reset() {
        last.removeAll()
        lastMs = nil
    }

    /// このフレームで検出した (番号, 枠) を渡すと，表示する枠を番号順で返す
    mutating func update(_ present: [(slot: Int, bbox: CGRect)], timestampMs: Int) -> [PersonBox] {
        if let lastMs, timestampMs < lastMs { reset() }
        lastMs = timestampMs
        var out: [PersonBox] = []
        let seen = Set(present.map(\.slot))
        for p in present {
            last[p.slot] = (p.bbox, timestampMs)
            out.append(PersonBox(slot: p.slot, bbox: p.bbox, detected: true))
        }
        for (slot, v) in last where !seen.contains(slot) {
            if timestampMs - v.ms > holdMs {
                last[slot] = nil
            } else {
                out.append(PersonBox(slot: slot, bbox: v.bbox, detected: false))
            }
        }
        return out.sorted { $0.slot < $1.slot }
    }
}

/// 録画（{stem}_people.json）から復元した，人物ごとの枠と指標の時系列。
/// 各人物エントリに "bbox" と "slot" が無い古い録画では nil（従来の 1 枚表示にフォールバックする）。
/// people.json にはワールド座標が無いため，人物ごとの体のヨーは出ない（PlaybackTimeline の CSV からの復元と同じ制約）。
nonisolated struct PeopleTrack: Sendable {
    /// 各フレームの timestamp_ms（metrics.csv と同じ値）
    let timestamps: [Int]
    /// 各フレームに出す枠（PersonHold を通した後）
    let boxes: [[PersonBox]]
    /// 人物番号 → 指標の時系列（timestamps と同じ長さ．その人がいないフレームは nil）
    let timelines: [Int: PlaybackTimeline]

    var slots: [Int] { timelines.keys.sorted() }
    var firstTimestamp: Int { timestamps.first ?? 0 }

    /// 動画ファイル（video_overlay / video_raw / video_skeleton のいずれか）から同じ録画の people.json を探す
    static func load(forVideo url: URL) -> PeopleTrack? {
        let name = url.deletingPathExtension().lastPathComponent
        var stem = name
        for suffix in ["_overlay", "_raw", "_skeleton"] where name.hasSuffix(suffix) {
            stem = String(name.dropLast(suffix.count))
        }
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let jsonURL = root.appendingPathComponent("json").appendingPathComponent(stem)
            .appendingPathComponent("\(stem)_people.json")
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        return parse(data)
    }

    /// people.json の中身を解析する。ランドマークは指標の計算にだけ使い，保持しない
    static func parse(_ data: Data) -> PeopleTrack? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func points(_ v: Any?) -> [Landmark] {
            guard let arr = v as? [[String: Any]] else { return [] }
            return arr.map { d in
                Landmark(x: (d["x"] as? NSNumber)?.doubleValue ?? 0, y: (d["y"] as? NSNumber)?.doubleValue ?? 0,
                         z: (d["z"] as? NSNumber)?.doubleValue ?? 0,
                         visibility: (d["visibility"] as? NSNumber)?.doubleValue ?? 1)
            }
        }
        var timestamps: [Int] = []
        var boxes: [[PersonBox]] = []
        var values: [Int: [MetricKind: [Float?]]] = [:]
        var previous: [Int: LandmarkFrame] = [:]
        var hold = PersonHold()
        var hasBoxes = false
        for (i, row) in rows.enumerated() {
            let ts = (row["timestamp_ms"] as? NSNumber)?.intValue ?? (timestamps.last ?? 0)
            timestamps.append(ts)
            var present: [(slot: Int, bbox: CGRect)] = []
            for person in row["people"] as? [[String: Any]] ?? [] {
                guard let slot = (person["slot"] as? NSNumber)?.intValue, slot >= 1,
                      let bbox = LandmarkFrame.parseBox(person["bbox"]),
                      !present.contains(where: { $0.slot == slot }) else { continue }
                hasBoxes = true
                present.append((slot, bbox))
                var f = LandmarkFrame.empty(timestampMs: ts)
                f.pose = points(person["pose"])
                f.face = points(person["face"])
                f.leftHand = points(person["left"])
                f.rightHand = points(person["right"])
                let m = MotionMetrics.compute(f, previous: previous[slot])
                previous[slot] = f
                if values[slot] == nil {
                    // 途中から現れた人は，それまでのフレームを欠損で埋める
                    var empty: [MetricKind: [Float?]] = [:]
                    for k in MetricKind.allCases { empty[k] = [Float?](repeating: nil, count: i) }
                    values[slot] = empty
                }
                for k in MetricKind.allCases { values[slot]![k]!.append(m[k].map(Float.init)) }
            }
            // このフレームにいない人は欠損
            for slot in values.keys {
                for k in MetricKind.allCases where values[slot]![k]!.count == i {
                    values[slot]![k]!.append(nil)
                }
            }
            boxes.append(hold.update(present, timestampMs: ts))
        }
        guard hasBoxes else { return nil }
        let timelines = values.mapValues { PlaybackTimeline(timestamps: timestamps, values: $0) }
        return PeopleTrack(timestamps: timestamps, boxes: boxes, timelines: timelines)
    }

    /// 動画の再生位置（秒）に対応するフレームの枠。動画の 0 秒は先頭フレームの timestamp_ms
    func boxes(atVideoTime seconds: Double) -> [PersonBox] {
        guard !timestamps.isEmpty else { return [] }
        let ms = firstTimestamp + Int((seconds * 1000).rounded())
        // timestamps は単調増加：ms 以下で最後のフレームを二分探索
        var lo = 0, hi = timestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timestamps[mid] <= ms { lo = mid + 1 } else { hi = mid }
        }
        return boxes[max(0, lo - 1)]
    }
}
