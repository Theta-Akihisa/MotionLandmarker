//
//  SkeletonRenderer.swift
//  MotionLandmarker
//
//  ランドマークを CoreGraphics で描画する。画面表示と録画（overlay / skeleton 動画）で共有。
//

import CoreGraphics
import Foundation

/// 画面表示で描く部位。録画では常に全部位を描く。
nonisolated struct DrawOptions: Equatable, Sendable {
    var face = true
    var pose = true
    var leftHand = true
    var rightHand = true
    static let all = DrawOptions()
}

/// 映像のランドマークとグラフの線で共通に使う色。部位ごとに 1 色を割り当てる。
/// グラフ側は SwiftUI の Color に変換して使う（ContentView 参照）。
nonisolated enum Palette {
    /// 顔のランドマーク／頭の向き
    static let face = CGColor(red: 0.4, green: 0.85, blue: 1.0, alpha: 1)
    /// 頭の向きグラフの 2・3 本目（顔色と同系統で区別できる色）
    static let faceAlt1 = CGColor(red: 0.45, green: 0.55, blue: 1.0, alpha: 1)
    static let faceAlt2 = CGColor(red: 0.8, green: 0.55, blue: 1.0, alpha: 1)
    /// 体（pose）の関節／体の向き
    static let body = CGColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1)
    /// 体の向きグラフの 2 本目
    static let bodyAlt = CGColor(red: 1.0, green: 0.6, blue: 0.75, alpha: 1)
    /// 体（pose）の骨線
    static let bodyLine = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
    /// 左手
    static let leftHand = CGColor(red: 0.35, green: 0.9, blue: 0.45, alpha: 1)
    /// 右手
    static let rightHand = CGColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1)
}

nonisolated enum SkeletonRenderer {
    static let poseLine = Palette.bodyLine
    static let poseJoint = Palette.body
    static let leftHand = Palette.leftHand
    static let rightHand = Palette.rightHand
    static let face = Palette.face
    static let sketchBackground = CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)

    /// `ctx` は左上原点（y 下向き）に設定済みであること。
    static func draw(_ frame: LandmarkFrame?, in ctx: CGContext, size: CGSize, options: DrawOptions = .all) {
        guard let frame else { return }
        let scale = max(1, min(size.width, size.height) / 720)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 顔（輪郭線 + 点）
        if options.face, frame.face.count == LandmarkFrame.faceCount {
            ctx.setStrokeColor(face)
            ctx.setLineWidth(1.5 * scale)
            let oval = LandmarkTopology.faceOval.map { point(frame.face[$0], size) }
            ctx.addLines(between: oval)
            ctx.strokePath()
            ctx.setFillColor(face)
            let r = 1.2 * scale
            for lm in frame.face {
                let p = point(lm, size)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }

        // 体
        if options.pose, frame.pose.count == LandmarkFrame.poseCount {
            ctx.setStrokeColor(poseLine)
            ctx.setLineWidth(4 * scale)
            for (a, b) in LandmarkTopology.poseConnections {
                let la = frame.pose[a], lb = frame.pose[b]
                guard la.visibility > 0.5, lb.visibility > 0.5 else { continue }
                ctx.move(to: point(la, size))
                ctx.addLine(to: point(lb, size))
            }
            // 前腕：pose の肘 → hand の手首。hand が検出されていない側は描かない。
            let forearms: [(Int, [Landmark])] = [
                (LandmarkTopology.poseElbow.left, frame.leftHand),
                (LandmarkTopology.poseElbow.right, frame.rightHand),
            ]
            for (elbow, hand) in forearms where hand.count == LandmarkFrame.handCount {
                let le = frame.pose[elbow]
                guard le.visibility > 0.5 else { continue }
                ctx.move(to: point(le, size))
                ctx.addLine(to: point(hand[0], size))
            }
            ctx.strokePath()
            ctx.setFillColor(poseJoint)
            let r = 5 * scale
            for (i, lm) in frame.pose.enumerated()
            where lm.visibility > 0.5 && !LandmarkTopology.poseHidden.contains(i) {
                let p = point(lm, size)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }

        if options.leftHand { drawHand(frame.leftHand, color: leftHand, ctx: ctx, size: size, scale: scale) }
        if options.rightHand { drawHand(frame.rightHand, color: rightHand, ctx: ctx, size: size, scale: scale) }
    }

    /// 背景（カメラ画像，無ければ sketchBackground）の上にランドマークを描く。
    /// `ctx` は CoreGraphics 標準の左下原点のままでよい。
    static func compose(_ frame: LandmarkFrame?, background: CGImage?, in ctx: CGContext,
                        size: CGSize, options: DrawOptions = .all) {
        let rect = CGRect(origin: .zero, size: size)
        if let background {
            ctx.draw(background, in: rect)
        } else {
            ctx.setFillColor(sketchBackground)
            ctx.fill(rect)
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(frame, in: ctx, size: size, options: options)
        ctx.restoreGState()
    }

    /// compose の結果を CGImage として返す（画面表示用）。
    static func image(_ frame: LandmarkFrame?, background: CGImage?, size: CGSize,
                      options: DrawOptions = .all) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        compose(frame, background: background, in: ctx, size: size, options: options)
        return ctx.makeImage()
    }

    private static func drawHand(_ hand: [Landmark], color: CGColor, ctx: CGContext, size: CGSize, scale: CGFloat) {
        guard hand.count == LandmarkFrame.handCount else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(3 * scale)
        for (a, b) in LandmarkTopology.handConnections {
            ctx.move(to: point(hand[a], size))
            ctx.addLine(to: point(hand[b], size))
        }
        ctx.strokePath()
        ctx.setFillColor(color)
        let r = 3.5 * scale
        for lm in hand {
            let p = point(lm, size)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }

    @inline(__always)
    private static func point(_ lm: Landmark, _ size: CGSize) -> CGPoint {
        CGPoint(x: lm.x * size.width, y: lm.y * size.height)
    }
}
