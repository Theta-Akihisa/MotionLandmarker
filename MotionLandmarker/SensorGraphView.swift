//
//  SensorGraphView.swift
//  MotionLandmarker
//

import SwiftUI
import Charts

struct SensorGraphView: View {
    let title: String
    let data: [Float]
    let color: Color
    let unit: String
    /// 縦軸の固定範囲。nil のときはデータの最小・最大に追従する。
    var fixedRange: ClosedRange<Float>? = nil
    /// 各サンプルの時刻（data と同じ長さ）。与えると横軸が実時間の間隔になる（目盛りは表示しない）。
    var times: [Date]? = nil

    private var currentValue: Float { data.last ?? 0 }
    private var yRange: ClosedRange<Float> {
        if let fixedRange { return fixedRange }
        let mn = (data.min() ?? 0) - 0.1
        let mx = (data.max() ?? 1) + 0.1
        return mn == mx ? (mn - 0.5)...(mx + 0.5) : mn...mx
    }
    /// 描画用データ。固定範囲のときは範囲内に丸め，グラフ枠からはみ出さないようにする
    private var plotData: [Float] {
        guard let r = fixedRange else { return data }
        return data.map { min(max($0, r.lowerBound), r.upperBound) }
    }
    private var useTimeAxis: Bool { times.map { $0.count == data.count && !$0.isEmpty } ?? false }
    private var timeDomain: ClosedRange<Date> {
        let last = times?.last ?? Date()
        let first = times?.first ?? last
        return first < last ? first...last : last.addingTimeInterval(-1)...last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(unit.isEmpty
                     ? String(format: "%.3f", currentValue)
                     : String(format: "%.3f \(unit)", currentValue))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Chart {
                // 現時点（最新サンプル）を示す縦線
                if useTimeAxis, let last = times?.last {
                    RuleMark(x: .value("Now", last))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                } else if !plotData.isEmpty {
                    RuleMark(x: .value("Now", plotData.count - 1))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(Array(plotData.enumerated()), id: \.offset) { index, value in
                    if useTimeAxis {
                        LineMark(x: .value("Time", times![index]), y: .value("Value", value))
                            .foregroundStyle(color)
                            .interpolationMethod(.catmullRom)
                    } else {
                        LineMark(x: .value("Sample", index), y: .value("Value", value))
                            .foregroundStyle(color)
                            .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartYScale(domain: yRange)
            // 範囲外へ膨らむ曲線はプロット領域だけで切る（軸ラベルは切らない）
            .chartPlotStyle { $0.clipped() }
            .chartYAxis {
                if fixedRange != nil {
                    AxisMarks(position: .leading,
                              values: [yRange.lowerBound, (yRange.lowerBound + yRange.upperBound) / 2, yRange.upperBound]) {
                        AxisGridLine()
                        AxisValueLabel(anchor: .trailing).font(.caption)
                    }
                }
            }
            .chartXScale(domain: useTimeAxis ? timeDomain : Date()...Date())
            .chartXAxis(.hidden)
            .frame(height: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}


/// 複数系列を色分けして 1 枚に重ねるグラフ。凡例に現在値を出す。
struct MultiSeriesGraphView: View {
    struct Series: Identifiable {
        let id: String
        let label: String
        /// nil は未検出（線を途切れさせる）
        let data: [Float?]
        let color: Color

        /// 連続して値がある区間ごとに分ける。区間ごとに別の系列として描くと線がつながらない。
        /// `stride` 個おきに間引く（欠損の境界は保つ）。
        func segments(stride: Int) -> [(run: Int, points: [(index: Int, value: Float)])] {
            var out: [(Int, [(Int, Float)])] = []
            var current: [(Int, Float)] = []
            for (i, v) in data.enumerated() {
                if let v {
                    if i % stride == 0 || current.isEmpty { current.append((i, v)) }
                } else if !current.isEmpty { out.append((out.count, current)); current = [] }
            }
            if !current.isEmpty { out.append((out.count, current)) }
            return out
        }
    }

    let title: String
    let series: [Series]
    let unit: String
    let range: ClosedRange<Float>
    var times: [Date]? = nil
    /// 横軸に表示する時間幅（秒）。常にこの幅で固定し，起動直後も右端から左へ流れる。
    var windowSeconds: TimeInterval = 10
    /// 1 系列あたりの描画点数の上限。これを超える分は間引く（描画コストを抑えるため）
    var maxPoints = 240
    /// 横軸の右端（現時点）。nil なら最新サンプルの時刻。再生時は動画の再生位置を渡す
    var endTime: Date? = nil

    private var count: Int { series.map(\.data.count).max() ?? 0 }
    private var stride: Int { max(1, count / maxPoints) }
    private var useTimeAxis: Bool { endTime != nil || (times.map { $0.count == count && !$0.isEmpty } ?? false) }
    private var lastTime: Date { endTime ?? times?.last ?? Date() }
    private var timeDomain: ClosedRange<Date> {
        lastTime.addingTimeInterval(-windowSeconds)...lastTime
    }

    private func clamp(_ v: Float) -> Float { min(max(v, range.lowerBound), range.upperBound) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                ForEach(series) { s in
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 11, height: 11)
                        Text(s.label).font(.title3)
                        // 値の有無や桁数で幅が変わらないよう固定幅にする（"-180.00" が収まる幅）
                        Text((s.data.last ?? nil).map { String(format: "%.2f", $0) } ?? "--")
                            .font(.title3).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }

            Chart {
                // 現在位置（再生中は再生位置）
                if useTimeAxis {
                    RuleMark(x: .value("Now", lastTime)).foregroundStyle(Color.red).lineStyle(StrokeStyle(lineWidth: 2.5))
                } else if count > 0 {
                    RuleMark(x: .value("Now", count - 1)).foregroundStyle(Color.red).lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                ForEach(series) { s in
                    ForEach(s.segments(stride: stride), id: \.run) { seg in
                        ForEach(seg.points, id: \.index) { pt in
                            if useTimeAxis, let times, pt.index < times.count {
                                LineMark(x: .value("Time", times[pt.index]), y: .value("Value", clamp(pt.value)),
                                         series: .value("Series", "\(s.id)-\(seg.run)"))
                                    .foregroundStyle(s.color)
                                    .interpolationMethod(.linear)
                            } else {
                                LineMark(x: .value("Sample", pt.index), y: .value("Value", clamp(pt.value)),
                                         series: .value("Series", "\(s.id)-\(seg.run)"))
                                    .foregroundStyle(s.color)
                                    .interpolationMethod(.linear)
                            }
                        }
                    }
                }
            }
            .chartYScale(domain: range)
            .chartPlotStyle { $0.clipped() }
            .chartYAxis {
                AxisMarks(position: .leading,
                          values: [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound]) {
                    AxisGridLine()
                    AxisValueLabel(anchor: .trailing).font(.body)
                }
            }
            .chartXScale(domain: useTimeAxis ? timeDomain : Date()...Date())
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
