// CodeNotch 1.20.0 / 6e8b0f8 TooltipCard shell, outline and contrast (MIT).
// Original silhouette/material; VitaPet uses a wider card for native-point text.
import AppKit
import SwiftUI
import UsageMonitor

/// The regular Liquid Glass material follows the desktop behind it. A dark
/// system appearance is not a guarantee of a dark result: a light wallpaper
/// can still make the card pale enough to erase secondary copy. Keep that
/// adaptive material, but give reading surfaces a stable dark base in this
/// one case.
enum UsageTooltipGlassContrast {
    static func needsReadableDim(surfaceStyle: UsageBarSurfaceStyle,
                                 colorScheme: ColorScheme,
                                 reduceTransparency: Bool = false) -> Bool {
        surfaceStyle.effective == .glass && colorScheme == .dark && !reduceTransparency
    }

    static func dim(surfaceStyle: UsageBarSurfaceStyle, colorScheme: ColorScheme,
                    reduceTransparency: Bool = false) -> Color? {
        if surfaceStyle.effective == .darkGlass {
            return UsageTooltipPalette.darkGlassTooltipDim
        }
        return needsReadableDim(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                reduceTransparency: reduceTransparency)
            ? UsageTooltipPalette.liquidGlassTooltipDim : nil
    }

    static func secondaryInk(surfaceStyle: UsageBarSurfaceStyle, colorScheme: ColorScheme,
                             reduceTransparency: Bool = false) -> Color {
        needsReadableDim(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                         reduceTransparency: reduceTransparency)
            ? UsageTooltipPalette.readableTooltipTextSecondary : UsageTooltipPalette.textSecondary
    }
}

/// The speech-bubble tail, its point aimed at the hovered cell.
///
/// Its shoulders leave the card tangent to the card's edge. That continuous
/// tangent is what makes the two pieces read as one moulded silhouette rather
/// than a triangle pasted onto a rounded rectangle.
struct UsageTooltipTail: Shape {
    /// Which way the card sits relative to the notch — the tip points back the
    /// other way, at the cell.
    let direction: UsageTooltipDirection

    func path(in rect: CGRect) -> Path {
        // The tip and the two ends of the base opposite it. Each curve starts
        // or finishes parallel to the card edge, rounding both joins while the
        // point stays crisp and continues to land on the hovered ring.
        let (tip, a, b, aShoulder, aTip, bTip, bShoulder):
            (CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint)
        switch direction {
        case .leading:   // card on the left, tip to the right
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.25)
        case .trailing:  // card on the right, tip to the left
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25)
        case .down:      // card below, tip upward
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY)
        case .up:        // card above, tip downward
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY)
        }

        var path = Path()
        path.move(to: a)
        path.addCurve(to: tip, control1: aShoulder, control2: aTip)
        path.addCurve(to: b, control1: bTip, control2: bShoulder)
        path.closeSubpath()
        return path
    }

    /// Long in the direction it points, wide across it.
    static func size(for direction: UsageTooltipDirection) -> CGSize {
        switch direction {
        case .leading, .trailing:
            return CGSize(width: UsageTooltipLayout.tailLength, height: UsageTooltipLayout.tailHeight)
        case .up, .down:
            return CGSize(width: UsageTooltipLayout.tailHeight, height: UsageTooltipLayout.tailLength)
        }
    }
}

/// The card and its tail as a single outline.
///
/// One glass shape, not two: separate ones each grow their own rim highlight
/// and the seam shows where the tail leaves the card. Internal so the tests can
/// measure the outline.
struct UsageTooltipSilhouette: Shape {
    /// Which side of the notch the card is on, so the tail goes on the other one.
    let direction: UsageTooltipDirection
    /// The same nudge `TooltipShell` applies to the tail view, along the card's
    /// own axis. The glass is masked by this outline, so a tail that has slid
    /// along the card to stay on its cell would otherwise be left unpainted.
    var tailOffset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // The two pieces are placed out of `rect` exactly the way
        // `TooltipShell.body` stacks them, so the outline keeps following the
        // card while its height animates.
        let tail = UsageTooltipTail.size(for: direction)
        let cardRect: CGRect
        var tailRect: CGRect
        switch direction {
        case .leading:
            cardRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width - tail.width, height: rect.height)
            tailRect = CGRect(x: cardRect.maxX, y: rect.midY - tail.height / 2,
                              width: tail.width, height: tail.height)
        case .trailing:
            tailRect = CGRect(x: rect.minX, y: rect.midY - tail.height / 2,
                              width: tail.width, height: tail.height)
            cardRect = CGRect(x: rect.minX + tail.width, y: rect.minY,
                              width: rect.width - tail.width, height: rect.height)
        case .down:
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: rect.minY,
                              width: tail.width, height: tail.height)
            cardRect = CGRect(x: rect.minX, y: rect.minY + tail.height,
                              width: rect.width, height: rect.height - tail.height)
        case .up:
            cardRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height - tail.height)
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: cardRect.maxY,
                              width: tail.width, height: tail.height)
        }
        var clampedTailOffset = tailOffset
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (cardRect.height / 2) - UsageTooltipLayout.cardCorner - (tail.height / 2))
            clampedTailOffset = min(max(tailOffset, -maxOffset), maxOffset)
            tailRect.origin.y += clampedTailOffset
        case .up, .down:
            let maxOffset = max(0, (cardRect.width / 2) - UsageTooltipLayout.cardCorner - (tail.width / 2))
            clampedTailOffset = min(max(tailOffset, -maxOffset), maxOffset)
            tailRect.origin.x += clampedTailOffset
        }

        return RoundedRectangle(cornerRadius: UsageTooltipLayout.cardCorner, style: .circular)
            .path(in: cardRect)
            .union(UsageTooltipTail(direction: direction).path(in: tailRect))
    }
}

/// The card chrome every tooltip shares: fixed width, the frame's padding and
/// corner, and the tail welded on so there is no seam between them.
struct UsageTooltipShell<Content: View>: View {
    /// Given explicitly rather than left to the contents.
    ///
    /// Sized by its contents, the card's height changes the instant they do —
    /// and the tail, centred on that height, jumps with it while the card's
    /// position is still gliding. The two halves then visibly come apart.
    let height: CGFloat
    /// Which side of the notch the card is on, so the tail goes on the other one.
    let direction: UsageTooltipDirection
    var tailOffset: CGFloat = 0
    @ViewBuilder let content: Content

    @Environment(\.usageReduceTransparency) private var reduceTransparency
    @Environment(\.usageTooltipSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    /// Reduce transparency means "no see-through chrome", which for this card
    /// is the solid style — the same precedence the Settings window applies to
    /// its own translucent chrome.
    private var glassy: Bool { surfaceStyle.usesGlass && !reduceTransparency }

    /// Clear on glass: anything of ours under it would override the Clear or
    /// Tinted choice in Appearance settings. `darkGlass` is the one deliberate
    /// exception, and its dim is drawn behind the glass itself, not here.
    private var surfaceFill: Color { glassy ? .clear : UsageTooltipPalette.card }

    private var card: some View {
        // The same arrangement that makes the notch fold work: the contents
        // are laid out once at their natural size and never move, and it is
        // the *mask* that changes size over them.
        //
        // The obvious alternative — putting the contents inside a frame of
        // the animating height — makes SwiftUI re-align them on every frame
        // of the animation, so the rows drift vertically inside the card and
        // the top ones slide out under the clip. Nothing should move here
        // except the boundary.
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: UsageTooltipLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: UsageTooltipLayout.cardWidth, height: height)

            content
                .padding(UsageTooltipLayout.cardPadding)
                .frame(width: UsageTooltipLayout.cardWidth, alignment: .topLeading)
        }
        .frame(width: UsageTooltipLayout.cardWidth, height: height, alignment: .top)
        .clipShape(
            RoundedRectangle(cornerRadius: UsageTooltipLayout.cardCorner, style: .circular)
        )
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: UsageTooltipLayout.cardCorner, style: .circular)
                    .strokeBorder(UsageTooltipPalette.ringTrack, lineWidth: 1)
            }
        }
    }

    private var clampedTailOffset: CGFloat {
        let size = UsageTooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (height / 2) - UsageTooltipLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (UsageTooltipLayout.cardWidth / 2) - UsageTooltipLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
    }

    private var tail: some View {
        let size = UsageTooltipTail.size(for: direction)
        // The tail is deliberately outside the clip: it is part of the card's
        // silhouette, not of its contents.
        return UsageTooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    var body: some View {
        stack
            // The background takes the stack's bounds — card plus tail — and is
            // re-solved as `height` animates, so one piece of glass covers both
            // pieces however tall the card is.
            .background {
                // `isGlass` is only ever true where `glassEffect` exists;
                // the availability check is what tells the compiler so. Below
                // that, `surfaceFill` has already painted the card opaque.
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.tooltipGlass, in: UsageTooltipSilhouette(direction: direction,
                                                                                   tailOffset: clampedTailOffset))
                            .background {
                                if let dim = UsageTooltipGlassContrast.dim(surfaceStyle: surfaceStyle,
                                                                      colorScheme: colorScheme,
                                                                      reduceTransparency: reduceTransparency) {
                                    UsageTooltipSilhouette(direction: direction, tailOffset: clampedTailOffset).fill(dim)
                                }
                            }
                    }
                }
            }
    }

    @ViewBuilder private var stack: some View {
        // Card first or tail first, laid out along whichever axis the tail
        // points. The pair is one silhouette either way.
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}


enum UsageTooltipDirection { case leading, trailing, up, down }

extension UsageBarSurfaceStyle {
    var effective: UsageBarSurfaceStyle { usesGlass ? self : .solid }
    @available(macOS 26.0, *)
    var tooltipGlass: Glass { self == .darkGlass ? .clear : .regular }
}

// Palette values and per-appearance resolution are unchanged from CodeNotch.
enum UsageTooltipPalette {
    static func color(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let card = Color.black
    static let ringTrack = color(dark: .white.withAlphaComponent(0.188), light: .black.withAlphaComponent(0.16))
    static let barTrack = color(dark: .white.withAlphaComponent(0.176), light: .black.withAlphaComponent(0.15))
    static let textPrimary = color(dark: .white, light: .black)
    static let textSecondary = color(dark: .init(white: 128.0 / 255, alpha: 1), light: .init(white: 107.0 / 255, alpha: 1))
    static let readableTooltipTextSecondary = color(dark: .init(white: 194.0 / 255, alpha: 1), light: .init(white: 107.0 / 255, alpha: 1))
    static let darkGlassTooltipDim = Color.black.opacity(0.80)
    static let liquidGlassTooltipDim = Color.black.opacity(0.35)
}

private struct UsageTooltipSurfaceKey: EnvironmentKey { static let defaultValue = UsageBarSurfaceStyle.glass }
private struct UsageTooltipSecondaryInkKey: EnvironmentKey { static let defaultValue = UsageTooltipPalette.textSecondary }
extension EnvironmentValues {
    var usageTooltipSurfaceStyle: UsageBarSurfaceStyle {
        get { self[UsageTooltipSurfaceKey.self] }
        set { self[UsageTooltipSurfaceKey.self] = newValue }
    }
    var tooltipSecondaryInk: Color {
        get { self[UsageTooltipSecondaryInkKey.self] }
        set { self[UsageTooltipSecondaryInkKey.self] = newValue }
    }
}
