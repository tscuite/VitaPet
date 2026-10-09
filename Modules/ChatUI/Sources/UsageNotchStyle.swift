// Adapted from CodeNotch 6e8b0f8 (MIT): Design, NotchLayout, Typography,
// SideNotchShape, NotchRootView and SettingsHandle. See THIRD_PARTY_NOTICES.md.
import AppKit
import SwiftUI
import UsageMonitor

/// Original design-frame measurements, not a second set of approximated UI sizes.
enum UsageNotchLayout {
    static let designScale: CGFloat = 44.0 / 117.0
    static func px(_ value: CGFloat) -> CGFloat { value * designScale }
    static let ringDiameter = px(117)
    static let trackStroke = px(15.5)
    static let progressStroke = px(8)
    static let glyphSize = px(46)
    static let ringLabelGap = px(26.9)
    static let percentFontSize = px(27) / 0.714
    static let curlRadius = px(103)
    static let cornerRadius = px(78.8)
    static let cellSpacing = px(83.5)
    static let padStart = (px(69.5) + px(50.1)) / 2
    static let bezelBleed: CGFloat = 2
    static let orbDiameter = px(124)
    static let orbStroke = px(18)
    static let orbClearance = px(39)
    static let orbExtent = px(152) / 2
    // Fixed point size/weight: pointer hit testing must not rebuild the font on every mouse move.
    static let percentLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: percentFontSize, weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }()
    static var cellExtent: CGFloat { ringDiameter + ringLabelGap + percentLineHeight }
    static var bodyDepth: CGFloat { px(186) - ringDiameter + cellExtent }
    static func shapeLength(count: Int) -> CGFloat {
        2 * curlRadius + 2 * padStart + CGFloat(count) * ringDiameter + CGFloat(max(0, count - 1)) * cellSpacing
    }

    // CodeNotch GooNeck.flareWalk, shared by the body and the settings arc.
    static let flareWalk: [(u: CGFloat, v: CGFloat, heading: CGFloat)] = {
        let p: CGFloat = 0.5, steps = 96
        let bend = (CGFloat.pi / 2) / (1 - p)
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(u: CGFloat, v: CGFloat, heading: CGFloat)] = [(0, 0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1)
            let before = heading
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v, (before + heading) / 2))
        }
        let end = walk[walk.count - 1]
        return walk.map { ($0.u / end.u, $0.v / end.v, $0.heading) }
    }()
}

/// The upstream steady, unjoined notch path; top/bottom only. No floating rounded rectangle.
struct UsageNotchShape: Shape {
    let edge: UsageBarEdge
    var scale: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        let depth = rect.height, length = rect.width
        let wanted = max(0, min(UsageNotchLayout.cornerRadius * scale, depth / 2))
        let hidden = max(0, min(UsageNotchLayout.bezelBleed, depth - wanted))
        let curl = max(0, min(UsageNotchLayout.curlRadius * scale, depth - wanted - hidden))
        let corner = max(0, min(wanted, (length - 2 * curl) / 2))
        var path = Path()
        path.move(to: CGPoint(x: depth, y: 0))
        if hidden > 0 { path.addLine(to: CGPoint(x: depth - hidden, y: 0)) }
        fluidTurn(&path, to: CGPoint(x: depth - hidden - curl, y: curl),
                  leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: -1, dy: 0))
        path.addLine(to: CGPoint(x: corner, y: curl))
        turn(&path, to: CGPoint(x: 0, y: curl + corner),
             leaving: CGVector(dx: -1, dy: 0), arriving: CGVector(dx: 0, dy: 1), radius: corner)
        path.addLine(to: CGPoint(x: 0, y: length - curl - corner))
        turn(&path, to: CGPoint(x: corner, y: length - curl),
             leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: 1, dy: 0), radius: corner)
        path.addLine(to: CGPoint(x: depth - hidden - curl, y: length - curl))
        fluidTurn(&path, to: CGPoint(x: depth - hidden, y: length),
                  leaving: CGVector(dx: 1, dy: 0), arriving: CGVector(dx: 0, dy: 1))
        if hidden > 0 { path.addLine(to: CGPoint(x: depth, y: length)) }
        path.closeSubpath()
        let transform = edge == .top
            ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: depth)
            : CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        return path.applying(transform).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private func fluidTurn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector) {
        guard let from = path.currentPoint else { return }
        let along = (to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy
        let across = (to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy
        guard along != 0, across != 0 else { path.addLine(to: to); return }
        for step in UsageNotchLayout.flareWalk.dropFirst() {
            path.addLine(to: CGPoint(x: from.x + leaving.dx * step.u * along + arriving.dx * step.v * across,
                                    y: from.y + leaving.dy * step.u * along + arriving.dy * step.v * across))
        }
    }

    private func turn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector, radius: CGFloat) {
        guard radius > 0, let from = path.currentPoint else { path.addLine(to: to); return }
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let out = abs(delta.dx * leaving.dx + delta.dy * leaving.dy)
        let into = abs(delta.dx * arriving.dx + delta.dy * arriving.dy)
        guard out > 0, into > 0 else { path.addLine(to: to); return }
        path.addCurve(to: to,
                      control1: CGPoint(x: from.x + leaving.dx * out * 0.5523, y: from.y + leaving.dy * out * 0.5523),
                      control2: CGPoint(x: to.x - arriving.dx * into * 0.5523, y: to.y - arriving.dy * into * 0.5523))
    }
}

/// Original FlareArc at rest: a parallel offset from the notch's curve, not an SF Symbol.
struct UsageNotchSettingsArc: Shape {
    let edge: UsageBarEdge
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / (2 * UsageNotchLayout.curlRadius)
        let flare = UsageNotchLayout.curlRadius * scale
        let gap = UsageNotchLayout.orbClearance * scale
        let bezel = CGPoint(x: 0, y: edge == .top ? -1 : 1)
        let side = CGPoint(x: -1, y: 0)
        var path = Path()
        for (index, step) in UsageNotchLayout.flareWalk.enumerated() {
            let x = rect.midX + flare * (1 - step.v) * bezel.x + flare * step.u * side.x
            let y = rect.midY + flare * (1 - step.v) * bezel.y + flare * step.u * side.y
            let nx = -sin(step.heading) * side.x - cos(step.heading) * bezel.x
            let ny = -sin(step.heading) * side.y - cos(step.heading) * bezel.y
            let point = CGPoint(x: x + nx * gap, y: y + ny * gap)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path.strokedPath(StrokeStyle(lineWidth: UsageNotchLayout.orbStroke * scale, lineCap: .round))
    }
}

extension UsageBarSurfaceStyle {
    var usesGlass: Bool {
        if #available(macOS 26.0, *) { return self != .solid }
        return false
    }

    public func panelAppearance(reduceTransparency: Bool) -> NSAppearance? {
        self == .glass && usesGlass && !reduceTransparency ? nil : NSAppearance(named: .darkAqua)
    }
}

// Like upstream, fixture overrides augment the real accessibility settings;
// macOS's own EnvironmentValues keys are read-only in the CLT SDK.
private struct UsageReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct UsageReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var usageReduceMotion: Bool {
        get { self[UsageReduceMotionKey.self] || accessibilityReduceMotion }
        set { self[UsageReduceMotionKey.self] = newValue }
    }
    var usageReduceTransparency: Bool {
        get { self[UsageReduceTransparencyKey.self] || accessibilityReduceTransparency }
        set { self[UsageReduceTransparencyKey.self] = newValue }
    }
}

/// Upstream renders glass on an oversized rectangle, then clips the notch out of it.
/// Dark glass is clear material over black, not a tint (which can make it lighter).
struct UsageNotchSurface: View {
    var style: UsageBarSurfaceStyle = .glass
    var interactive = false
    @Environment(\.usageReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            if #available(macOS 26.0, *), style.usesGlass, !reduceTransparency {
                let glass = style == .darkGlass ? Glass.clear : Glass.regular
                Color.clear
                    .frame(width: proxy.size.width + 400, height: proxy.size.height + 400)
                    .glassEffect(interactive ? glass.interactive() : glass, in: Rectangle())
                    .background {
                        if style == .darkGlass { Color.black.opacity(0.60) }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                Color.black
            }
        }
    }
}
