import AppKit
import SwiftUI

import IslandCore

/// One row, the question, up to four options or the error line, and "+N more" (spec §7.3).
/// Geometry comes from PeekCardMetrics (IslandCore), which the panel model also uses for the
/// interactive region, so what is drawn and what takes clicks never drift apart.
struct PeekCardView: View {
    let card: PeekCard
    let title: String
    let layout: NotchLayout
    let onClick: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @AppStorage("glassFrostRadiusPill") private var frostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var tintOpacity = NotchGlassStyle.defaultTintOpacity

    private var shape: HangingNotchShape {
        HangingNotchShape(
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onClick) {
                cardContent
                    .frame(width: PeekCardMetrics.cardWidth(for: layout), alignment: .leading)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .background(
                NotchGlassScrim(
                    silhouette: shape,
                    barBandHeight: 0,
                    presentation: .pill,
                    tintOpacity: tintOpacity
                )
            )
            .background(NotchGlassBackdrop(presentation: .pill, frostRadius: frostRadius))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PeekCardHeightKey.self, value: proxy.size.height)
                }
            }
            .frame(maxHeight: PeekCardMetrics.maximumHeight, alignment: .top)
            .offset(y: PeekCardMetrics.top(for: layout))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PeekCardHeightKey.self) { height in
            onHeightChange(height)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PeekStatusDot(style: card.row.state.indicatorStyle)
                PeekSourceGlyph(source: card.row.source)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !card.row.subtitle.isEmpty {
                    Text(card.row.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(card.bodyText)
                .font(.system(size: 13))
                .foregroundStyle(card.event.kind == .error ? Color.red.opacity(0.95) : Color.white)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if !card.optionLabels.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(card.optionLabels.enumerated()), id: \.offset) { index, label in
                        Text("\(index + 1). \(label)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            if card.moreCount > 0 {
                Text("+\(card.moreCount) more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var accessibilityText: String {
        var parts = [title, card.row.state.accessibilityName, card.bodyText]
        if card.moreCount > 0 { parts.append("\(card.moreCount) more") }
        return parts.joined(separator: ", ")
    }
}

private struct PeekCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The row's status light, colored like the board's (DisplayState.indicatorStyle).
private struct PeekStatusDot: View {
    let style: StatusIndicatorStyle

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch style {
        case .spinner: .white
        case .uncertain: .white.opacity(0.5)
        case .mutedDot: .gray
        case .greenDot: .green
        case .orangeDot: .orange
        case .redDot: .red
        }
    }
}

/// Bundled Claude/Codex marks, loaded once; Herdr (no bundled mark) uses an SF Symbol.
private enum PeekSourceIcons {
    static let bySource: [SessionSource: NSImage] = Dictionary(
        SessionSource.allCases.compactMap { source in
            guard let url = BundledResources.iconURL(for: source),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (source, image)
        },
        uniquingKeysWith: { $1 }
    )
}

private struct PeekSourceGlyph: View {
    let source: SessionSource

    var body: some View {
        if let image = PeekSourceIcons.bySource[source] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
    }
}
