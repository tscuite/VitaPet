// CodeNotch 1.20.0 / 6e8b0f8 NotchLayout and Typography (MIT).
import AppKit
import SwiftUI
import UsageMonitor

/// The tooltip keeps readable native-point text even when the quota strip is scaled.
enum UsageTooltipLayout {
    static func px(_ value: CGFloat) -> CGFloat { UsageNotchLayout.px(value) }
    static let bodyFontSize: CGFloat = 12
    static let titleFontSize: CGFloat = 15
    static let cardWidth: CGFloat = 320
    static let cardCorner = px(49.5)
    static let cardPadding = px(32)
    static let tailLength = px(75)
    static let tailHeight = px(87)
    static let tailGap = px(28)
    static let barHeight = px(10.5)
    static let headerGap = px(17)
    static let headerToBlock = px(21)
    static let labelToBar = px(16.8)
    static let barToUsed = px(17.8)
    static let blockSpacing = px(20)
    static let statusDotGap = px(11)
    static let hairline = px(2.5)
    static let codexUsageTop = px(20)
    static let codexMetricTop = px(14)
    static let codexMetricRowGap = px(8)
    static let codexMetricRowHeight = px(40)
    static let codexMetricHeight = 5 * codexMetricRowHeight + 4 * codexMetricRowGap
    static let codexMetricBottom = px(14)
    static let codexUsageRowGap = px(12)
    static let codexChartTop = px(15)
    static let codexChartHeight = px(115)
    static let titleFont = Font.system(size: titleFontSize, weight: .semibold)
    static let bodyFont = Font.system(size: bodyFontSize, weight: .regular)
    @MainActor static let cardBodyFont = NSFont.systemFont(ofSize: bodyFontSize, weight: .regular)
    @MainActor static let cardBodyLineHeight = ceil(cardBodyFont.ascender - cardBodyFont.descender + cardBodyFont.leading)
    static let cardTitleLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }()
    @MainActor static var codexResetCreditsHeight: CGFloat {
        blockSpacing + 3 * cardBodyLineHeight + 2 * codexUsageRowGap
    }

    @MainActor static func bodyTextHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: cardWidth - 2 * cardPadding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: cardBodyFont])
        return CGFloat(max(1, Int((bounds.height / cardBodyLineHeight).rounded(.up)))) * cardBodyLineHeight
    }

    /// Original cardHeight branches for Codex: plan, windows/groups, resets, account statistics.
    @MainActor static func height(reading: UsageReading, now: Date, statusMessage: String?) -> CGFloat {
        let header = max(UsageNotchLayout.glyphSize, cardTitleLineHeight)
            + (reading.plan == nil ? 0 : cardBodyLineHeight)
        var height = 2 * cardPadding + header
        let count = reading.limits.count
        if statusMessage == nil, count > 0 {
            let fullBlock = 2 * cardBodyLineHeight + labelToBar + barHeight + barToUsed
            height += headerToBlock + CGFloat(count) * fullBlock + CGFloat(count - 1) * blockSpacing
            let groups = Set(reading.limits.compactMap(\.group)).count
            if groups > 0 {
                height += CGFloat(groups) * (cardBodyLineHeight + px(12) + 2 * px(16))
                height += CGFloat(max(0, groups - 1)) * (px(28) - blockSpacing) + px(8)
            }
        } else {
            height += headerToBlock + bodyTextHeight(statusMessage ?? "")
        }
        if let credits = reading.resetCredits?.unexpired(at: now), credits.availableCount > 0 {
            height += codexUsageTop + hairline + codexResetCreditsHeight
        }
        if reading.tokenUsage != nil {
            height += codexUsageTop + hairline + blockSpacing
                + codexMetricTop + codexMetricHeight + codexMetricBottom + hairline
                + 2 * cardBodyLineHeight + codexUsageRowGap + codexChartTop + codexChartHeight
        }
        return height
    }
}
