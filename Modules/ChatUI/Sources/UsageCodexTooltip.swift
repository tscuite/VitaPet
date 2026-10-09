// CodeNotch 1.20.0 / 6e8b0f8 TooltipCard header, rows, metrics, resets and daily chart (MIT).
import SwiftUI
import Localization
import UsageMonitor

private struct UsageTooltipHeader<Mark: View>: View {
    let title: String
    /// The account's named tier, when the provider publishes one.
    var subtitle: String?
    /// Sits on the header's own line, so saying when a reading was taken costs
    /// the card no extra height.
    var note: String?
    @ViewBuilder let mark: Mark
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        HStack(alignment: .center, spacing: UsageTooltipLayout.headerGap) {
            mark
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(UsageTooltipLayout.titleFont)
                        .foregroundStyle(UsageTooltipPalette.textPrimary)
                        // The title names the model; a long note yields before it does.
                        .layoutPriority(1)
                    if let note {
                        Spacer(minLength: UsageTooltipLayout.px(20))
                        Text(note)
                            .font(UsageTooltipLayout.bodyFont)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(UsageTooltipLayout.bodyFont)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A label on the left and a quieter value on the right — the row shape the
/// design frame uses throughout.
struct UsageTooltipSplitRow<Accessory: View>: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = UsageTooltipPalette.textPrimary
    var trailingColor: Color? = nil
    /// Sits immediately before the trailing text, inside the same group, so it
    /// travels with the word instead of drifting to the middle of the row.
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        HStack(spacing: UsageTooltipLayout.px(20)) {
            Text(leading).foregroundStyle(leadingColor)
            Spacer(minLength: 0)
            HStack(spacing: UsageTooltipLayout.statusDotGap) {
                accessory()
                Text(trailing).foregroundStyle(trailingColor ?? secondaryInk)
            }
        }
        .font(UsageTooltipLayout.bodyFont)
        .lineLimit(1)
    }
}

extension UsageTooltipSplitRow where Accessory == EmptyView {
    init(leading: String,
         trailing: String,
         leadingColor: Color = UsageTooltipPalette.textPrimary,
         trailingColor: Color? = nil) {
        self.init(leading: leading, trailing: trailing,
                  leadingColor: leadingColor, trailingColor: trailingColor,
                  accessory: { EmptyView() })
    }
}

private struct CodexMetric: Identifiable {
    let id: String
    let value: String
    let label: String
}

private struct CodexMetricList: View {
    let metrics: [CodexMetric]
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        VStack(alignment: .leading, spacing: UsageTooltipLayout.codexMetricRowGap) {
            ForEach(metrics) { metric in
                HStack(alignment: .firstTextBaseline, spacing: UsageTooltipLayout.px(20)) {
                    Text(metric.label)
                        .font(UsageTooltipLayout.bodyFont)
                        .foregroundStyle(UsageTooltipPalette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(metric.value)
                        .font(UsageTooltipLayout.bodyFont)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .frame(height: UsageTooltipLayout.codexMetricRowHeight)
            }
        }
        .frame(height: UsageTooltipLayout.codexMetricHeight)
    }
}

private struct CodexDailyUsageChart: View {
    let buckets: [CodexTokenUsage.DailyBucket]
    let maximum: Int
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(UsageTooltipPalette.ringTrack)
                    .frame(height: UsageTooltipLayout.hairline)

                HStack(alignment: .bottom, spacing: UsageTooltipLayout.px(4)) {
                    ForEach(buckets) { bucket in
                        RoundedRectangle(cornerRadius: UsageTooltipLayout.px(3), style: .continuous)
                            .fill(secondaryInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: proxy.size.height
                                   * CGFloat(bucket.tokens) / CGFloat(maximum))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: UsageTooltipLayout.codexChartHeight)
        .clipped()
    }
}

/// Unused rate-limit resets on this account.
private struct UsageResetCreditsSection: View {
    let credits: UsageResetCredits
    let now: Date
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var countText: String {
        switch credits.availableCount {
        case 0: return L10n.tr("usage.codex.no_resets")
        case 1: return L10n.tr("usage.codex.one_reset")
        case let n: return UsageTooltipCopy.format("usage.codex.reset_count", n)
        }
    }

    private var observedCountText: String {
        guard let checkedAt = credits.checkedAt else { return countText }
        return UsageTooltipCopy.format("usage.codex.reset_observed", countText, UsageTooltipCopy.age(since: checkedAt, now: now))
    }

    private var expiryText: String? {
        guard credits.availableCount > 0, let date = credits.nextExpiry, date > now else {
            return nil
        }
        let stamp = Self.stamp(for: date, now: now)
        return credits.availableCount > 1
            ? UsageTooltipCopy.format("usage.codex.next_expires", stamp)
            : UsageTooltipCopy.format("usage.codex.expires", stamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(UsageTooltipPalette.ringTrack)
                .frame(height: UsageTooltipLayout.hairline)
                .padding(.top, UsageTooltipLayout.codexUsageTop)

            VStack(alignment: .leading, spacing: 0) {
                Text(credits.checkedAt == nil
                     ? L10n.tr("usage.codex.resets") : L10n.tr("usage.codex.resets_cached"))
                    .font(UsageTooltipLayout.bodyFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(UsageTooltipPalette.textPrimary)
                    .padding(.top, UsageTooltipLayout.blockSpacing)

                Text(observedCountText)
                    .font(UsageTooltipLayout.bodyFont)
                    .foregroundStyle(UsageTooltipPalette.textPrimary)
                    .lineLimit(1)
                    .padding(.top, UsageTooltipLayout.codexUsageRowGap)

                if let expiryText {
                    Text(expiryText)
                        .font(UsageTooltipLayout.bodyFont)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .padding(.top, UsageTooltipLayout.codexUsageRowGap)
                }
            }
            .frame(height: UsageTooltipLayout.codexResetCreditsHeight, alignment: .top)
        }
    }

    /// Same date templates `UsageResetCopy` uses past the hour, so this line and
    /// the quota rows agree on what "soon" looks like.
    private static func stamp(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = UsageResetCopy.formatter(for: calendar)
        formatter.locale = Locale(identifier: L10n.locale)
        if UsageResetCopy.daysApart(from: now, to: date, calendar: calendar) >= 7 {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("E j:mm")
        }
        return formatter.string(from: date)
    }
}

/// Account-wide Codex activity. Unlike the quota rows above, this is sourced
/// from the Codex profile usage endpoint and is not a local estimate.
private struct CodexUsageSection: View {
    let usage: CodexTokenUsage
    let now: Date

    private var buckets: [CodexTokenUsage.DailyBucket] {
        usage.last30Days(now: now)
    }

    private var maximum: Int {
        max(1, buckets.map(\.tokens).max() ?? 0)
    }

    private var todayText: String {
        usage.usageToday(now: now).map { UsageTokenFormat.tokens($0) } ?? L10n.tr("usage.codex.pending")
    }

    private var metrics: [CodexMetric] {
        let summary = usage.summary
        return [
            CodexMetric(id: "lifetime", value: UsageTokenFormat.tokens(summary?.lifetimeTokens),
                        label: L10n.tr("usage.codex.lifetime")),
            CodexMetric(id: "peak", value: UsageTokenFormat.tokens(summary?.peakDailyTokens),
                        label: L10n.tr("usage.codex.peak")),
            CodexMetric(id: "longest", value: UsageTokenFormat.duration(
                seconds: summary?.longestRunningTurnSeconds), label: L10n.tr("usage.codex.longest_chat")),
            CodexMetric(id: "current-streak", value: UsageTokenFormat.days(
                summary?.currentStreakDays), label: L10n.tr("usage.codex.current_streak")),
            CodexMetric(id: "longest-streak", value: UsageTokenFormat.days(
                summary?.longestStreakDays), label: L10n.tr("usage.codex.longest_streak"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(UsageTooltipPalette.ringTrack)
                .frame(height: UsageTooltipLayout.hairline)
                .padding(.top, UsageTooltipLayout.codexUsageTop)

            CodexMetricList(metrics: metrics)
                .padding(.top, UsageTooltipLayout.codexMetricTop)
                .padding(.bottom, UsageTooltipLayout.codexMetricBottom)

            Rectangle()
                .fill(UsageTooltipPalette.ringTrack)
                .frame(height: UsageTooltipLayout.hairline)

            UsageTooltipSplitRow(leading: L10n.tr("usage.codex.today"), trailing: todayText)
                .padding(.top, UsageTooltipLayout.blockSpacing)
            UsageTooltipSplitRow(leading: L10n.tr("usage.codex.last30"),
                     trailing: UsageTokenFormat.tokens(usage.usageInLast30Days(now: now)))
                .padding(.top, UsageTooltipLayout.codexUsageRowGap)
            CodexDailyUsageChart(buckets: buckets, maximum: maximum)
                .padding(.top, UsageTooltipLayout.codexChartTop)
        }
    }
}

/// Original LimitWindowRow's quota-only branch, including the used/left pair and pace.
private struct UsageCodexWindowRow: View {
    let window: UsageLimit
    var inset: CGFloat = 0
    let now: Date
    let settings: UsageCodexSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var trackWidth: CGFloat { UsageTooltipLayout.cardWidth - 2 * UsageTooltipLayout.cardPadding - inset }
    private var fillWidth: CGFloat {
        max(UsageTooltipLayout.barHeight, trackWidth * CGFloat(min(max(window.usedFraction ?? 0, 0), 1)))
    }
    private var barColor: Color {
        if (window.usedFraction ?? 0) >= 0.7 { return Color(red: 1, green: 63.0 / 255, blue: 0) }
        if (window.usedFraction ?? 0) >= 0.5 {
            return colorScheme == .dark ? Color(red: 242.0 / 255, green: 1, blue: 0)
                : Color(red: 176.0 / 255, green: 136.0 / 255, blue: 0)
        }
        return Color(nsColor: .controlAccentColor)
    }
    private var paceText: Text {
        guard settings.showUsagePace, let pace = window.usagePace(now: now) else { return Text("") }
        let text = UsageTooltipCopy.format(pace.isDeficit ? "usage.codex.deficit" : "usage.codex.reserved", pace.value)
        return Text(" · \(text)").foregroundColor(pace.isDeficit ? .orange : secondaryInk)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageTooltipSplitRow(leading: UsageTooltipCopy.windowTitle(window.title),
                trailing: window.resetsAt.map { UsageResetCopy.text(for: $0, now: now, format: settings.resetTimeFormat) } ?? "")
            if window.usedFraction != nil {
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageTooltipPalette.barTrack)
                    Capsule().fill(barColor).frame(width: fillWidth)
                }
                .frame(width: trackWidth, height: UsageTooltipLayout.barHeight)
                .padding(.top, UsageTooltipLayout.labelToBar)
            }
            Text("\(UsageTooltipCopy.summary(window))\(paceText)")
                .font(UsageTooltipLayout.bodyFont)
                .foregroundStyle(UsageTooltipPalette.textPrimary)
                .lineLimit(1)
                .padding(.top, UsageTooltipLayout.barToUsed)
        }
    }
}

/// TooltipCard / ProviderTooltip's original Codex branches; no replacement dashboard.
struct UsageCodexTooltip: View {
    let reading: UsageReading
    let now: Date
    var direction: UsageTooltipDirection = .down
    var tailOffset: CGFloat = 0
    @Environment(\.usageTooltipSurfaceStyle) private var surfaceStyle
    @Environment(\.usageReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private struct WindowGroup: Identifiable {
        let id: String
        let title: String?
        var windows: [UsageLimit]
    }
    private var groupedWindows: [WindowGroup] {
        var result: [WindowGroup] = []
        for window in reading.limits {
            if let last = result.last, last.title == window.group {
                result[result.count - 1].windows.append(window)
            } else {
                result.append(WindowGroup(id: window.group ?? window.id, title: window.group, windows: [window]))
            }
        }
        return result
    }
    private var statusMessage: String? {
        switch reading.status {
        case .disabled: return L10n.tr("usage.off_hint")
        case .notConnected: return L10n.tr("usage.codex.sign_in")
        case .failed, .rateLimited: return reading.detail.map(UsagePresentation.detail) ?? UsagePresentation.status(reading.status)
        case .ready, .stale: return reading.limits.isEmpty ? L10n.tr("usage.no_reading") : nil
        }
    }
    private var readingAge: String? {
        if reading.detail?.contains(UsageFailure.googleUnavailable.errorDescription!) == true {
            return L10n.tr("usage.google_blocked")
        }
        guard reading.status == .stale, let updated = reading.updatedAt else { return nil }
        return UsageTooltipCopy.age(since: updated, now: now)
    }
    private var settings: UsageCodexSettings { reading.codexSettings ?? UsageCodexSettings() }

    var body: some View {
        UsageTooltipShell(height: UsageTooltipLayout.height(reading: reading, now: now, statusMessage: statusMessage),
                          direction: direction, tailOffset: tailOffset) {
            VStack(alignment: .leading, spacing: 0) {
                UsageTooltipHeader(title: L10n.tr("usage.codex.title"), subtitle: reading.plan, note: readingAge) {
                    UsageProviderGlyph(provider: .codex)
                        .scaleEffect(1.08 * 0.94)
                        .frame(width: UsageNotchLayout.glyphSize, height: UsageNotchLayout.glyphSize)
                        .foregroundStyle(UsageTooltipPalette.textPrimary)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(UsageTooltipLayout.bodyFont)
                        .foregroundStyle(UsageTooltipPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, UsageTooltipLayout.headerToBlock)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedWindows.enumerated()), id: \.element.id) { groupIndex, group in
                            if let title = group.title {
                                VStack(alignment: .leading, spacing: UsageTooltipLayout.px(12)) {
                                    Text(title == "Code review" ? L10n.tr("usage.codex.code_review") : title)
                                        .font(UsageTooltipLayout.bodyFont).fontWeight(.semibold)
                                        .foregroundStyle(UsageTooltipPalette.textPrimary)
                                        .padding(.leading, UsageTooltipLayout.px(4))
                                    VStack(alignment: .leading, spacing: UsageTooltipLayout.blockSpacing) {
                                        ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                                            UsageCodexWindowRow(window: window, inset: 2 * UsageTooltipLayout.px(16), now: now, settings: settings)
                                                .padding(.top, index == 0 ? 0 : UsageTooltipLayout.blockSpacing)
                                        }
                                    }
                                    .padding(UsageTooltipLayout.px(16))
                                    .overlay(RoundedRectangle(cornerRadius: UsageTooltipLayout.px(20))
                                        .stroke(Color.white.opacity(0.25), lineWidth: UsageTooltipLayout.px(1.5)))
                                }
                                .padding(.top, groupIndex == 0 ? UsageTooltipLayout.headerToBlock : UsageTooltipLayout.px(28))
                            } else {
                                ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                                    UsageCodexWindowRow(window: window, now: now, settings: settings)
                                        .padding(.top, groupIndex == 0 && index == 0 ? UsageTooltipLayout.headerToBlock : UsageTooltipLayout.blockSpacing)
                                }
                            }
                        }
                    }
                    .padding(.bottom, groupedWindows.contains { $0.title != nil } ? UsageTooltipLayout.px(8) : 0)
                }
                if let credits = reading.resetCredits?.unexpired(at: now), credits.availableCount > 0 {
                    UsageResetCreditsSection(credits: credits, now: now)
                }
                if let usage = reading.tokenUsage { CodexUsageSection(usage: usage, now: now) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(reading.id + "-" + L10n.locale)
        }
        .environment(\.tooltipSecondaryInk, UsageTooltipGlassContrast.secondaryInk(
            surfaceStyle: surfaceStyle, colorScheme: colorScheme, reduceTransparency: reduceTransparency))
    }
}
