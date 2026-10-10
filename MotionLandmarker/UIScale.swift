//
//  UIScale.swift
//  MotionLandmarker
//
//  ⌘+ / ⌘- / ⌘0 で画面全体の文字・ボタンの大きさを段階的に変える。
//  文字はシステムの文字サイズ段階（dynamicTypeSize）で，固定サイズ（アイコン，ラベル幅など）は倍率で連動させる。
//

import SwiftUI

enum UIScale {
    static let key = "uiScaleStep"
    static let range = -3...4

    /// 段階 → 文字サイズ段階（0 が既定）
    static func typeSize(for step: Int) -> DynamicTypeSize {
        switch step {
        case ...(-3): return .xSmall
        case -2: return .small
        case -1: return .medium
        case 0: return .large
        case 1: return .xLarge
        case 2: return .xxLarge
        case 3: return .xxxLarge
        default: return .accessibility1
        }
    }

    /// 段階 → 固定サイズに掛ける倍率（1 段あたり約 12%）
    static func factor(for step: Int) -> CGFloat {
        pow(1.12, CGFloat(step))
    }

    static func clamp(_ step: Int) -> Int { min(max(step, range.lowerBound), range.upperBound) }
}

/// 固定サイズに掛ける倍率を各ビューへ渡す
private struct UIScaleFactorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleFactorKey.self] }
        set { self[UIScaleFactorKey.self] = newValue }
    }
}
