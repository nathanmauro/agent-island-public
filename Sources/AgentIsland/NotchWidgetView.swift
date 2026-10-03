import AppKit
import Combine
import SwiftUI

import IslandCore

struct NotchPointerSnapshot: Equatable {
    let isInside: Bool
    let revision: UInt
}

/// The AppKit hosting view owns one fixed tracking area for its entire
/// lifetime. SwiftUI observes its normalized result instead of replacing a
/// tracking area every time the hanging card changes height.
@MainActor
final class NotchPointerTracker: ObservableObject {
    @Published private(set) var snapshot = NotchPointerSnapshot(
        isInside: false,
        revision: 0
    )
    let hoverExpansionRequests = PassthroughSubject<DisplayPoint, Never>()
    /// The panel controller closes an expanded board through this after a
    /// display change or wake (PanelAnchorPlan.collapseBoard).
    let collapseRequests = PassthroughSubject<Void, Never>()
    private var reducer = PointerSampleReducer()

    @discardableResult
    func update(isInside: Bool, location: DisplayPoint) -> DisplayPoint {
        let reduction = reducer.reduce(isInside: isInside, location: location)
        if let containment = reduction.containmentChange {
            snapshot = NotchPointerSnapshot(
                isInside: containment.isInside,
                revision: containment.revision
            )
        }
        return reduction.location
    }

    func requestHoverExpansion(at location: DisplayPoint) {
        hoverExpansionRequests.send(location)
    }

    func requestCollapse() {
        collapseRequests.send(())
    }
}

struct NotchWidgetView: View {
    @Bindable var store: StateStore
    @AppStorage(PreferenceKeys.hideWhenEmpty) private var hideWhenEmpty = false
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity
    @Environment(\.openSettings) private var openSettings
    let layout: NotchLayout
    @ObservedObject var pointerTracker: NotchPointerTracker
    let requestPointerRefresh: () -> Void
    let onInteractiveRegionChange: (HangingNotchInteractionRegion) -> Void
    let onKeyboardFocusChange: (Bool) -> Void
    let onMenuVisibilityChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var collapseWorkItem: DispatchWorkItem?
    @State private var hoverExpandWorkItem: DispatchWorkItem?
    @State private var isHoveringPanel = false
    @State private var openMenuTrackingCount = 0
    @State private var rowInteractionActive = false
    @State private var outsideClickMonitor: Any?
    @State private var latestMeasuredContentHeight: CGFloat = 0

    var body: some View {
        let summary = store.summary
        let warnings = store.warningSources
        let shouldHide = summary.isEmpty && warnings.isEmpty && hideWhenEmpty
        let bar = barGeometry(summary: summary, showsWarning: !warnings.isEmpty)
        let barWidth = bar.leftWidth + layout.notchWidth + bar.rightWidth
        let barLeadingOffset = layout.barLeadingOffset(
            leftWidth: bar.leftWidth,
            rightWidth: bar.rightWidth
        )
        let menuWidth = layout.width
        // The notch's straight sides sit a shoulder radius inside the panel,
        // so its card content narrows by the same amount per side to keep
        // the visual margin the bubble gets from its own edges.
        let menuContentWidth = NotchLayout.contentWidth(forExpandedPanelWidth: menuWidth)
            - 2 * layout.expandedContentSideInset
        let headerWings = layout.expandedHeaderWingWidths()
        let compactInteractiveFrame = DisplayFrame(
            minX: barLeadingOffset,
            minY: layout.topGap,
            width: barWidth,
            height: layout.height
        )

        // One view tree for both presentations: the bar never leaves the
        // hierarchy, so expanding animates the shared silhouette growing out
        // of the notch instead of cross-fading between two layouts. The bar
        // stays pinned to the camera housing the whole time: the outer offset
        // and the row's inner offset always sum to barLeadingOffset.
        ZStack(alignment: .topLeading) {
            if !shouldHide {
                VStack(alignment: .leading, spacing: 0) {
                    // The top row swaps between the compact status bar and the
                    // expanded header living in the wings beside the camera.
                    // Both layers stay resident: each inner offset cancels the
                    // outer animated offset, so every camera cutout remains
                    // pinned over the housing for the whole spring and the
                    // swap reads as a pure cross-fade. Opacity-0 views still
                    // hit-test, hence the explicit gates.
                    ZStack(alignment: .topLeading) {
                        Button(action: openMenu) {
                            barRow(bar: bar, summary: summary, warnings: warnings)
                                .contentShape(silhouette)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(summary.isEmpty ? "Show agents" : "Show agents: \(summary.text)")
                        .frame(width: barWidth, height: layout.height)
                        .offset(x: isExpanded ? barLeadingOffset : 0)
                        .opacity(isExpanded ? 0 : 1)
                        .allowsHitTesting(!isExpanded)

                        expandedHeaderRow(
                            agentCount: store.rows.count,
                            warnings: warnings,
                            wings: headerWings
                        )
                        .frame(width: menuWidth, height: layout.height)
                        .offset(x: isExpanded ? 0 : -barLeadingOffset)
                        .opacity(isExpanded ? 1 : 0)
                        .allowsHitTesting(isExpanded)
                    }
                    if isExpanded {
                        SessionMenuCard(
                            store: store,
                            rows: store.rows,
                            listMaximumHeight: SessionMenuLayout.boardListMaximumHeight(
                                boardMaxHeight: layout.boardMaxHeight
                            ),
                            isPointerInside: isHoveringPanel,
                            dismiss: collapseMenu,
                            setKeyboardFocus: onKeyboardFocusChange,
                            onRowInteractionChange: { isActive in
                                rowInteractionActive = isActive
                                if isActive {
                                    cancelPendingCollapse()
                                } else {
                                    settleAfterDetachedInteraction()
                                }
                            }
                        )
                        .frame(width: menuContentWidth)
                        .frame(width: menuWidth, alignment: .center)
                        .transition(.opacity)
                    }
                }
                .frame(width: isExpanded ? menuWidth : barWidth, alignment: .topLeading)
                // The pill's expanded bubble has no camera band above the
                // header, so it gains breathing room between its rounded top
                // edge and the title, plus matching room under the last row;
                // collapsed keeps the tight capsule.
                .padding(.top, isExpanded ? layout.expandedHeaderTopPadding : 0)
                .padding(.bottom, isExpanded ? layout.expandedBottomPadding : 0)
                .background(
                    // The band beside the camera stays explicit pure black so
                    // the drop reads as part of the screen edge; below it the
                    // scrim fades into behind-window glass. Pill mode has no
                    // camera to hide and keeps a flat tint over the glass.
                    NotchGlassScrim(
                        silhouette: silhouette,
                        barBandHeight: layout.height,
                        presentation: layout.presentation,
                        tintOpacity: layout.presentation == .pill
                            ? pillTintOpacity : notchTintOpacity
                    )
                )
                .background(
                    NotchGlassBackdrop(
                        presentation: layout.presentation,
                        frostRadius: layout.presentation == .pill
                            ? pillFrostRadius : notchFrostRadius
                    )
                )
                // Do not clip the compact counters to the curved silhouette:
                // the physical camera already owns the central cutout, while
                // clipping here shaves off the leading spinner before it can
                // reach the safe area beside that cutout.
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: InteractiveHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                // Gestures live on the silhouette, not the outer frame: the
                // panel is always expanded-height, so the outer frame covers
                // transparent dead space below the visible shape.
                .contentShape(silhouette)
                .contextMenu {
                    SettingsLink {
                        Label("Agent Island Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit Agent Island", systemImage: "power")
                    }
                }
                // A session row's context menu is an NSMenu window outside
                // this view: opening it fires a hover exit that would
                // collapse the panel — and the menu with it — mid-read.
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
                ) { _ in
                    openMenuTrackingCount += 1
                    cancelPendingCollapse()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
                ) { _ in
                    openMenuTrackingCount = max(0, openMenuTrackingCount - 1)
                    settleAfterDetachedInteraction()
                }
                // Offset the rendered surface *after* attaching its shape and
                // hover tracking. Applying offset first leaves those later
                // modifiers at the unshifted panel origin: pill hover then
                // misses entirely and notch hover lands in empty space to the
                // left of the visible bar. The vertical offset floats the pill
                // below the screen edge — further while the bubble is open;
                // the notch keeps zero gap in both states.
                .offset(
                    x: isExpanded ? 0 : barLeadingOffset,
                    y: isExpanded ? layout.expandedTopGap : layout.topGap
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
            value: isExpanded
        )
        .onChange(of: pointerTracker.snapshot) { _, snapshot in
            handlePointerContainmentChange(snapshot)
        }
        .onReceive(pointerTracker.hoverExpansionRequests) { location in
            handleHoverExpansionRequest(location, compactFrame: compactInteractiveFrame)
        }
        .onReceive(pointerTracker.collapseRequests) { _ in
            collapseMenu()
        }
        .onAppear {
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
            requestPointerRefresh()
            onMenuVisibilityChange(isExpanded)
        }
        .onPreferenceChange(InteractiveHeightPreferenceKey.self) { measuredHeight in
            latestMeasuredContentHeight = measuredHeight
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: measuredHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
        }
        .onChange(of: isExpanded) { _, isVisible in
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isVisible,
                isHidden: shouldHide
            )
            updateOutsideClickMonitor(menuIsVisible: isVisible)
            onMenuVisibilityChange(isVisible)
        }
        .onChange(of: compactInteractiveFrame) { _, newFrame in
            publishInteractiveRegion(
                compactFrame: newFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
            requestPointerRefresh()
        }
        .onChange(of: shouldHide) { _, isHidden in
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: isHidden
            )
        }
        .onDisappear {
            updateOutsideClickMonitor(menuIsVisible: false)
            onMenuVisibilityChange(false)
        }
        .onChange(of: store.rows.isEmpty) { _, isNowEmpty in
            if isNowEmpty { collapseMenu() }
        }
    }

    // MARK: Bar

    /// Widths and contents of the compact bar. The pill spells the summary
    /// out ("1 error · 1 waiting · 3 working · 2 done") in one centered
    /// capsule. The hardware notch keeps glyph+count indicators in the two
    /// wings beside the camera, so the wings never grow over menu items:
    /// working, stale and done on the left, error and waiting (and the offline
    /// warning) on the right.
    private struct BarGeometry {
        let leftEntries: [Summary.Segment]
        let rightEntries: [Summary.Segment]
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let showsIdleMark: Bool
        let showsWarning: Bool
    }

    private func barGeometry(summary: Summary, showsWarning: Bool) -> BarGeometry {
        switch layout.presentation {
        case .pill:
            return BarGeometry(
                leftEntries: summary.segments,
                rightEntries: [],
                leftWidth: PillLabelMetrics.barWidth(
                    segments: summary.segments,
                    showsWarning: showsWarning,
                    maximum: layout.width
                ),
                rightWidth: 0,
                showsIdleMark: summary.isEmpty,
                showsWarning: showsWarning
            )
        case .notch:
            let left = summary.segments.filter { $0.kind == .working || $0.kind == .stale || $0.kind == .done }
            let right = summary.segments.filter { $0.kind == .error || $0.kind == .waiting }
            let showsIdleMark = summary.isEmpty && !showsWarning
            let naturalLeft = layout.statusWingWidth(
                side: .left,
                visibleIndicatorCount: left.count,
                showsIdleMark: showsIdleMark
            )
            let naturalRight = layout.statusWingWidth(
                side: .right,
                visibleIndicatorCount: right.count + (showsWarning ? 1 : 0),
                showsIdleMark: false
            )
            let wings = layout.balancedStatusWingWidths(
                leftWidth: naturalLeft,
                rightWidth: naturalRight
            )
            return BarGeometry(
                leftEntries: left,
                rightEntries: right,
                leftWidth: wings.left,
                rightWidth: wings.right,
                showsIdleMark: showsIdleMark,
                showsWarning: showsWarning
            )
        }
    }

    @ViewBuilder
    private func barRow(bar: BarGeometry, summary: Summary, warnings: [SessionSource]) -> some View {
        switch layout.presentation {
        case .pill:
            pillBar(bar: bar, summary: summary, warnings: warnings)
        case .notch:
            notchBar(bar: bar, warnings: warnings)
        }
    }

    /// Full-word labels, readable on the ultrawide without clicking. The
    /// error label leads (Summary's fixed order) and is red; waiting is
    /// orange; working and done are white. With nothing to count the pill
    /// keeps a dim moon.
    private func pillBar(bar: BarGeometry, summary: Summary, warnings: [SessionSource]) -> some View {
        HStack(spacing: 0) {
            if bar.showsIdleMark {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(width: PillLabelMetrics.glyphWidth)
                    .accessibilityLabel("No agents need you")
            }
            ForEach(Array(summary.segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Text(PillLabelMetrics.separator)
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(segment.label)
                    .foregroundStyle(pillLabelColor(segment.kind))
            }
            if bar.showsWarning {
                warningGlyph(warnings)
                    .padding(.leading, PillLabelMetrics.glyphSpacing)
            }
        }
        .font(Font(PillLabelMetrics.font as CTFont))
        .lineLimit(1)
        .fixedSize()
        .frame(width: bar.leftWidth, height: layout.height)
        .accessibilityElement(children: .combine)
    }

    private func pillLabelColor(_ kind: Summary.Segment.Kind) -> Color {
        switch kind {
        case .error: .red
        case .waiting: .orange
        case .working, .done: .white.opacity(0.94)
        case .stale: .white.opacity(0.7)
        }
    }

    /// The hardware-notch bar: wings span the full bar height so the click
    /// targets reach the top edge of the screen — the natural place to slam
    /// the pointer. Only states with a nonzero count take up a slot. Every
    /// indicator is a fixed slot and wing widths add up exactly, so padding
    /// stays symmetric — no slack parked at either end.
    private func notchBar(bar: BarGeometry, warnings: [SessionSource]) -> some View {
        HStack(spacing: 0) {
            Group {
                if bar.leftEntries.isEmpty {
                    if bar.showsIdleMark {
                        // Quiet empty state: the app is awake but no agent
                        // needs counting.
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("No agents need you")
                    }
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: layout.leftStatusWingLeadingPadding)
                        HStack(spacing: NotchLayout.statusIndicatorSpacing) {
                            ForEach(bar.leftEntries) { entry in
                                StatusSummaryIndicator(
                                    kind: entry.kind,
                                    count: entry.count,
                                    indicatorLayout: .forWing(.left)
                                )
                            }
                        }
                        Spacer(minLength: layout.leftStatusWingTrailingPadding)
                    }
                    .frame(width: bar.leftWidth, height: layout.height, alignment: .leading)
                }
            }
            .frame(width: bar.leftWidth, height: layout.height, alignment: .leading)
            Color.clear
                .frame(width: layout.notchWidth, height: layout.height)
            Group {
                if !bar.rightEntries.isEmpty || bar.showsWarning {
                    HStack(spacing: 0) {
                        Spacer(minLength: layout.rightStatusWingLeadingPadding)
                        HStack(spacing: NotchLayout.statusIndicatorSpacing) {
                            ForEach(bar.rightEntries) { entry in
                                StatusSummaryIndicator(
                                    kind: entry.kind,
                                    count: entry.count,
                                    indicatorLayout: .forWing(.right)
                                )
                            }
                            if bar.showsWarning {
                                warningGlyph(warnings)
                                    .frame(width: NotchLayout.statusIndicatorSlotWidth)
                            }
                        }
                        Spacer(minLength: layout.rightStatusWingTrailingPadding)
                    }
                    .frame(width: bar.rightWidth, height: layout.height, alignment: .trailing)
                }
            }
            .frame(width: bar.rightWidth, height: layout.height, alignment: .trailing)
        }
    }

    /// Shown only while a feed is offline or disabled. Hovering it names the
    /// feed and its health; the open board's header repeats the same text.
    private func warningGlyph(_ warnings: [SessionSource]) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.yellow)
            .frame(width: PillLabelMetrics.glyphWidth)
            .help(warningText(warnings, separator: "\n"))
            .accessibilityLabel(warningText(warnings, separator: ", "))
    }

    private func warningText(_ warnings: [SessionSource], separator: String) -> String {
        warnings.map { source in
            "\(source.displayName): \(store.feedHealth[source]?.summary ?? "offline")"
        }
        .joined(separator: separator)
    }

    /// Expanded replacement for the compact bar row: the menu header claims
    /// the wings beside the camera cutout instead of a row below it, so the
    /// space flanking the housing carries information rather than padding.
    /// Fixed-height frames center the content vertically in both bar heights.
    private func expandedHeaderRow(
        agentCount: Int,
        warnings: [SessionSource],
        wings: (left: CGFloat, right: CGFloat)
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if warnings.isEmpty {
                    Text("Agents")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.yellow)
                    Text(warningText(warnings, separator: " · "))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.yellow.opacity(0.85))
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(
                .leading,
                SessionMenuLayout.expandedHeaderLeadingInset + layout.expandedContentSideInset
            )
            .frame(width: wings.left, height: layout.height, alignment: .leading)
            Color.clear
                .frame(width: layout.notchWidth, height: layout.height)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(agentCount, format: .number)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
                SettingsGearButton {
                    // The settings window is a normal app window: activate
                    // first so it opens frontmost and key — the notch panel
                    // itself never takes that role.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    collapseMenu()
                }
            }
            .padding(
                .trailing,
                SessionMenuLayout.expandedHeaderTrailingInset + layout.expandedContentSideInset
            )
            .frame(width: wings.right, height: layout.height, alignment: .trailing)
        }
        .lineLimit(1)
    }

    /// Bar and menu share one silhouette. On a notched display the top
    /// shoulders curve inward from the screen edge while the lower corners
    /// remain circular; the detached pill instead rounds every corner — a
    /// capsule collapsed, a bubble expanded. Compact and expanded use
    /// identical radii; expansion only adds the straight sides between them.
    private var silhouette: HangingNotchShape {
        HangingNotchShape(
            style: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
    }

    // MARK: Menu visibility

    private static let hoverExpandDelay: TimeInterval = 0.15

    private func scheduleExpansion() {
        guard !isExpanded, hoverExpandWorkItem == nil else { return }
        let workItem = DispatchWorkItem {
            isExpanded = true
            hoverExpandWorkItem = nil
        }
        hoverExpandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay, execute: workItem)
    }

    private func openMenu() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        isExpanded = true
    }

    private func publishInteractiveRegion(
        compactFrame: DisplayFrame,
        measuredContentHeight: CGFloat,
        isExpanded: Bool,
        isHidden: Bool
    ) {
        let frame = HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: layout.width,
            expandedMaximumHeight: layout.expandedHeight,
            measuredContentHeight: measuredContentHeight,
            isExpanded: isExpanded,
            isHidden: isHidden,
            expandedTopInset: layout.expandedTopGap
        )
        let region = HangingNotchInteractionRegion(
            frame: frame,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
        onInteractiveRegionChange(region)
    }

    private func collapseMenu() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        isExpanded = false
    }

    private func cancelPendingCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    /// Collapse shortly after the pointer leaves the panel, mirroring how
    /// notch utilities dismiss. Inline row interactions keep it open.
    private func scheduleCollapseOnHoverExit() {
        cancelPendingCollapse()
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        guard HoverInteraction.shouldCollapse(
            isExpanded: isExpanded,
            isHoveringPanel: isHoveringPanel,
            openMenuTrackingCount: openMenuTrackingCount,
            rowInteractionActive: rowInteractionActive
        ) else { return }
        let workItem = DispatchWorkItem {
            guard HoverInteraction.shouldCollapse(
                isExpanded: isExpanded,
                isHoveringPanel: isHoveringPanel,
                openMenuTrackingCount: openMenuTrackingCount,
                rowInteractionActive: rowInteractionActive
            ) else { return }
            collapseWorkItem = nil
            isExpanded = false
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func handlePointerContainmentChange(_ snapshot: NotchPointerSnapshot) {
        if snapshot.isInside {
            isHoveringPanel = true
            cancelPendingCollapse()
        } else {
            isHoveringPanel = false
            hoverExpandWorkItem?.cancel()
            hoverExpandWorkItem = nil
            scheduleCollapseOnHoverExit()
        }
    }

    private func handleHoverExpansionRequest(
        _ location: DisplayPoint,
        compactFrame: DisplayFrame
    ) {
        guard HoverInteraction.shouldScheduleExpansion(
            pointer: location,
            compactFrame: compactFrame,
            panelOriginX: layout.originX,
            panelTopY: layout.originY + layout.height,
            isExpanded: isExpanded,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ) else { return }
        scheduleExpansion()
    }

    private func settleAfterDetachedInteraction() {
        guard !rowInteractionActive else { return }
        requestPointerRefresh()
        DispatchQueue.main.async {
            if isHoveringPanel {
                cancelPendingCollapse()
            } else {
                scheduleCollapseOnHoverExit()
            }
        }
    }

    private func updateOutsideClickMonitor(menuIsVisible: Bool) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard menuIsVisible else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            collapseMenu()
        }
    }

}

/// Text metrics for the pill's labels. The bar width feeds the interactive
/// region before SwiftUI lays anything out, so it is measured with the exact
/// font the labels render with.
private enum PillLabelMetrics {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let separator = " · "
    static let edgePadding: CGFloat = 12
    static let glyphWidth: CGFloat = 14
    static let glyphSpacing: CGFloat = 6
    static let minimumWidth: CGFloat = 46

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    static func barWidth(segments: [Summary.Segment], showsWarning: Bool, maximum: CGFloat) -> CGFloat {
        var content: CGFloat
        if segments.isEmpty {
            content = glyphWidth
        } else {
            content = segments.map { textWidth($0.label) }.reduce(0, +)
                + CGFloat(segments.count - 1) * textWidth(separator)
        }
        if showsWarning {
            content += glyphSpacing + glyphWidth
        }
        let upperBound = max(minimumWidth, maximum)
        return min(max(minimumWidth, content + 2 * edgePadding), upperBound)
    }
}

struct HangingNotchShape: Shape {
    var style: HangingNotchCornerStyle = .hangingNotch
    var topShoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topShoulderRadius, bottomCornerRadius) }
        set {
            topShoulderRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(HangingNotchGeometry.path(
            in: rect,
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        ))
    }
}

private struct InteractiveHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Status indicators

/// One compact status counter in a hardware-notch wing. Zero-count states
/// never reach this view — the summary filters them out — so every glyph on
/// the bar earns its space.
private struct StatusSummaryIndicator: View {
    let kind: Summary.Segment.Kind
    let count: Int
    /// Which edge the dot rides. The right wing mirrors the pair so the round
    /// dot — not the flat numeral — meets the notch shoulder, matching the
    /// left wing and reading as symmetric bookends.
    var indicatorLayout: StatusIndicatorLayout = .forWing(.left)

    var body: some View {
        HStack(spacing: 3) {
            if indicatorLayout.dotEdge == .leading {
                glyph
                countText
            } else {
                countText
                glyph
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        // Fixed slot: the wing-width formula in NotchLayout adds up to
        // exactly the rendered bar, preserving each side's intended padding.
        .frame(width: NotchLayout.statusIndicatorSlotWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(kind.rawValue)")
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind.indicatorStyle {
        case .spinner:
            WorkingPixelSpinner()
        case .uncertain:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        case .greenDot, .orangeDot, .redDot, .mutedDot:
            Circle()
                .fill(indicatorColor(for: kind.indicatorStyle))
                .frame(width: 8, height: 8)
        }
    }

    private var countText: some View {
        Text(count, format: .number)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
    }
}

/// The classic braille dot-matrix spinner used across CLI tools — several
/// dots lit per frame rather than one pixel chasing itself. Monochrome by
/// design so the colored dots remain easy to distinguish from active work.
private struct WorkingPixelSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrailleSpinnerView(animated: !reduceMotion)
            .frame(width: BrailleSpinnerHostView.side, height: BrailleSpinnerHostView.side)
    }
}

/// Bridges the Core Animation spinner into SwiftUI. The glyph cycle runs on
/// the render server rather than through a `TimelineView`: a periodic
/// TimelineView commits a CoreAnimation transaction every frame, and each
/// commit forces `NSHostingView` to re-lay-out the entire notch tree — ~12.5
/// full relayouts per second, which profiling showed to be the app's dominant
/// idle CPU (and battery) cost. A discrete `CAKeyframeAnimation` steps the
/// pre-rendered frames on the compositor with no SwiftUI graph update at all,
/// so the animation looks and steps identically while the main thread sleeps.
private struct BrailleSpinnerView: NSViewRepresentable {
    let animated: Bool

    func makeNSView(context: Context) -> BrailleSpinnerHostView {
        BrailleSpinnerHostView()
    }

    func updateNSView(_ view: BrailleSpinnerHostView, context: Context) {
        view.animated = animated
    }
}

/// An `NSView` whose backing layer cycles the braille frames via Core
/// Animation. Frames are rendered once per backing scale and reused across
/// every spinner on screen.
private final class BrailleSpinnerHostView: NSView {
    static let side: CGFloat = 11

    var animated = true {
        didSet {
            guard animated != oldValue else { return }
            reinstallAnimation()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .center
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reinstallAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reinstallAnimation()
    }

    private static let animationKey = "brailleSpinner"

    /// (Re)renders the frames at the current scale and drives them with a
    /// discrete keyframe animation. `beginTime` is aligned to the shared media
    /// clock so independently mounted spinners step in lockstep.
    private func reinstallAnimation() {
        guard let layer, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        let frames = Self.frames(scale: scale)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.contents = frames.first

        guard animated else { return }
        let period = BrailleSpinner.cyclePeriod
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        let now = CACurrentMediaTime()
        animation.beginTime = layer.convertTime(
            now - now.truncatingRemainder(dividingBy: period), from: nil
        )
        layer.add(animation, forKey: Self.animationKey)
    }

    private static let framesLock = NSLock()
    private static var framesByScale: [CGFloat: [CGImage]] = [:]

    private static func frames(scale: CGFloat) -> [CGImage] {
        framesLock.lock()
        defer { framesLock.unlock() }
        if let cached = framesByScale[scale] { return cached }
        let rendered = BrailleSpinner.frames.map { render($0, scale: scale) }
        framesByScale[scale] = rendered
        return rendered
    }

    /// Draws one glyph white-on-clear: `.system(size: 14, weight: .medium,
    /// design: .monospaced)`, centered in the 11×11 slot.
    private static func render(_ character: Character, scale: CGFloat) -> CGImage {
        let pixels = Int((side * scale).rounded())
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let glyph = NSAttributedString(string: String(character), attributes: attributes)
        let bounds = glyph.size()
        glyph.draw(at: CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}

/// Shared colors for compact and per-row status dots.
private func indicatorColor(for style: StatusIndicatorStyle) -> Color {
    switch style {
    case .spinner, .uncertain: .white
    case .mutedDot: .gray
    case .greenDot: .green
    case .orangeDot: .orange
    case .redDot: .red
    }
}

/// The visible route into the native Settings window, living in the expanded
/// bar's right wing; the silhouette's right-click menu stays as the fallback.
private struct SettingsGearButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.75 : 0.35))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Agent Island settings")
    }
}

// MARK: - Board

/// The expanded board: Waiting, Error, Working, Done, then a collapsed
/// "N idle" toggle, in compact 28 pt rows, never taller than the layout's
/// board cap (longer boards scroll inside it).
private struct SessionMenuCard: View {
    let store: StateStore
    let rows: [AgentRow]
    /// `SessionMenuLayout.boardListMaximumHeight(boardMaxHeight:)` for this display.
    let listMaximumHeight: CGFloat
    /// The monitor-driven containment `NotchWidgetView` already tracks
    /// (`isHoveringPanel`, fed by the always-on pointer monitor via
    /// `pointerTracker.snapshot`), not a tracking-area `.onHover` of our
    /// own: a raw `.onHover` on this card would miss exits whenever the
    /// panel's window flips `ignoresMouseEvents` or the card's tracking
    /// area is torn down and rebuilt mid-spring (every actions or idle
    /// toggle animates this card), which would hold a stale freeze open.
    let isPointerInside: Bool
    let dismiss: () -> Void
    let setKeyboardFocus: (Bool) -> Void
    let onRowInteractionChange: (Bool) -> Void
    @State private var errorMessage: String?
    // At most one row shows its inline actions; opening another closes it.
    @State private var actionsRowID: RowID?
    @State private var idleExpanded = false
    @State private var branchCoordinator = GitBranchResolutionCoordinator()
    /// The row order this menu opened with, held for as long as it is on
    /// screen so no row can slide out from under the pointer mid-reach.
    @State private var pinnedOrder = PinnedSessionOrder()
    /// Each row's group captured the moment `isPointerInside` last became
    /// true, held for as long as it stays true. The pin above guards a
    /// row's *slot*; this guards its *group* — without it, a row that
    /// finishes mid-reach jumps to Done and every row below shifts, landing
    /// a click on whatever took its place. `nil` while the pointer is
    /// outside the board.
    @State private var frozenAssignment: [RowID: BoardGroup.Kind]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let groups = BoardLayout.groups(pinnedOrder.ordered(rows), frozenAssignment: frozenAssignment)
        let visibleRowCount = groups.reduce(0) { count, group in
            count + (showsRows(of: group) ? group.rows.count : 0)
        }
        // Whether the row whose actions are open is still on screen. Every
        // trigger that can hide it — its group collapsing, it departing, its
        // state moving it to a different group while unfrozen, or the freeze
        // itself releasing and regrouping it into the collapsed idle group —
        // changes `groups` or `showsRows`, so this single derived value
        // reacts to all of them; no rowID means nothing to release.
        let isOpenActionsRowVisible = actionsRowID.map { rowID in
            groups.contains { group in
                showsRows(of: group) && group.rows.contains { $0.id == rowID }
            }
        } ?? true
        VStack(alignment: .leading, spacing: SessionMenuLayout.cardStackSpacing) {
            if groups.isEmpty {
                Text("No agents")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                // The list owns the extra height from inline actions. Past
                // the board cap it scrolls instead of growing past the panel.
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                groupHeader(group)
                                if showsRows(of: group) {
                                    ForEach(group.rows) { row in
                                        rowView(for: row)
                                            .id(row.id)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: SessionMenuLayout.boardListHeight(
                        rowCount: visibleRowCount,
                        groupCount: groups.count,
                        hasExpandedActions: actionsRowID != nil,
                        maximumHeight: listMaximumHeight
                    ))
                    .onChange(of: actionsRowID) { _, rowID in
                        guard let rowID else { return }
                        DispatchQueue.main.async {
                            withAnimation(
                                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
                            ) {
                                proxy.scrollTo(rowID, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(.bottom, SessionMenuLayout.sessionListBottomPadding)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, SessionMenuLayout.contentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SessionMenuLayout.listTopPadding)
        .padding(.bottom, SessionMenuLayout.cardBottomPadding)
        // The whole panel can collapse while a row interaction is open;
        // the interaction lock must not outlive the card.
        .onDisappear {
            onRowInteractionChange(false)
            frozenAssignment = nil
        }
        .onAppear { pinnedOrder.record(rows) }
        // Only appearances and departures need learning for the pin itself:
        // a state change redraws a row's own content in place (or, while
        // frozen, keeps its group too), and the pin absorbs any reordering.
        // Rows keep their group for as long as the pointer stays on the
        // board and regroup the moment it leaves (see `isPointerInside`
        // below); a departure is handled by the `isOpenActionsRowVisible`
        // watcher, not here.
        .onChange(of: rows.map(\.id)) { _, _ in pinnedOrder.record(rows) }
        // The freeze covers exactly the reach a click needs: captured the
        // moment the monitor-driven pointer state says the board is under
        // the pointer (including the instant it opens under an already
        // stationary pointer, via `initial: true`), held for as long as
        // that state stays true, released the moment it goes false.
        .onChange(of: isPointerInside, initial: true) { _, isInside in
            if isInside {
                frozenAssignment = frozenAssignment ?? BoardLayout.groupAssignment(rows)
            } else {
                frozenAssignment = nil
            }
        }
        // Whatever hid the open row — a collapse, a departure, a live state
        // change, or the freeze itself letting go — this is the one place
        // that releases it.
        .onChange(of: isOpenActionsRowVisible) { _, isVisible in
            guard !isVisible else { return }
            releaseActionsIfHidden()
        }
    }

    private func showsRows(of group: BoardGroup) -> Bool {
        !group.isCollapsedByDefault || idleExpanded
    }

    /// The row whose actions are open can be hidden out from under them —
    /// its group collapsed (the idle toggle) or it departed the board.
    /// Left open, the list keeps reserving 111 pt of blank space for a row
    /// nobody can see, and that reservation blocks hover-exit collapse.
    private func releaseActionsIfHidden() {
        guard let actionsRowID else { return }
        let groups = BoardLayout.groups(pinnedOrder.ordered(rows), frozenAssignment: frozenAssignment)
        let isVisible = groups.contains { group in
            showsRows(of: group) && group.rows.contains { $0.id == actionsRowID }
        }
        guard !isVisible else { return }
        self.actionsRowID = nil
        onRowInteractionChange(false)
    }

    @ViewBuilder
    private func groupHeader(_ group: BoardGroup) -> some View {
        if group.isCollapsedByDefault {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
                    idleExpanded.toggle()
                }
                // No explicit release here: toggling idleExpanded changes
                // `showsRows`, which the `isOpenActionsRowVisible` watcher
                // above already reacts to.
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: idleExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(group.title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(BoardGroupHeaderStyle(kind: group.kind))
            .accessibilityLabel(idleExpanded ? "Hide \(group.title) agents" : "Show \(group.title) agents")
        } else {
            HStack(spacing: 0) {
                Text(group.title)
                Spacer(minLength: 0)
            }
            .modifier(BoardGroupHeaderStyle(kind: group.kind))
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func rowView(for row: AgentRow) -> some View {
        SessionRow(
            row: row,
            title: store.displayName(for: row),
            renamePrefill: store.nameOverrides.displayName(for: row.id) ?? "",
            health: store.feedHealth[row.source],
            isActionsExpanded: actionsRowID == row.id,
            toggleActions: { toggleActions(for: row) },
            focus: { focus(row) },
            requestDetail: { store.requestDetail(row.id) },
            rename: { store.rename(row.id, to: $0) },
            setKeyboardFocus: setKeyboardFocus,
            branchCoordinator: branchCoordinator
        )
    }

    private func toggleActions(for row: AgentRow) {
        withAnimation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
        ) {
            actionsRowID = actionsRowID == row.id ? nil : row.id
        }
        onRowInteractionChange(actionsRowID != nil)
    }

    /// Keep the clicked result across task scheduling and navigation. The feed acknowledges
    /// it only after a successful jump, provided no newer result has superseded it.
    private func focus(_ row: AgentRow) {
        Task { @MainActor in
            do {
                try await store.focus(row)
                errorMessage = nil
                dismiss()
            } catch {
                errorMessage = "Could not jump to this agent."
            }
        }
    }
}

private struct BoardGroupHeaderStyle: ViewModifier {
    let kind: BoardGroup.Kind

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.leading, SessionMenuLayout.sessionRowLeadingInset)
            .padding(.trailing, 10)
            .frame(height: SessionMenuLayout.groupHeaderHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color {
        switch kind {
        case .error: .red.opacity(0.85)
        case .waiting: .orange.opacity(0.85)
        case .stale: .white.opacity(0.65)
        case .working, .done, .idle: .white.opacity(0.4)
        }
    }
}

// MARK: - Source glyphs

/// SVG brand marks bundled in IslandCore; NSImage renders SVG natively on
/// macOS 11+ so no rasterized assets are needed. Herdr has no bundled mark
/// and falls back to an SF Symbol.
private enum AgentIcons {
    static let bySource: [SessionSource: NSImage] = Dictionary(
        SessionSource.allCases.compactMap { source in
            // A brand mark is decoration: an unreadable resource bundle must
            // degrade the row to the symbol fallback, never take the panel down.
            guard let iconURL = BundledResources.iconURL(for: source),
                  let image = NSImage(contentsOf: iconURL) else { return nil }
            return (source, image)
        },
        uniquingKeysWith: { $1 }
    )
}

private struct AgentIconView: View {
    let source: SessionSource

    var body: some View {
        if let image = AgentIcons.bySource[source] {
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

// MARK: - Rows

private struct SessionRow: View {
    let row: AgentRow
    let title: String
    let renamePrefill: String
    let health: FeedHealth?
    let isActionsExpanded: Bool
    let toggleActions: () -> Void
    let focus: () -> Void
    let requestDetail: () -> Void
    let rename: (String) -> Void
    let setKeyboardFocus: (Bool) -> Void
    let branchCoordinator: GitBranchResolutionCoordinator

    /// Sub-modes of the inline action area: the button strip or the rename
    /// field. Both live inside the row itself so nothing ever floats outside
    /// the notch silhouette.
    private enum ActionMode { case menu, renaming }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var branchName: String?
    @State private var mode: ActionMode = .menu
    @State private var renameDraft = ""
    /// Which action entry the pointer is on, keyed by label. One selection for
    /// the whole list, so an exit that arrives late cannot unlight the entry
    /// the pointer actually reached.
    @State private var hoveredAction = HoverSelection<String>()
    /// Measured width of the inline menu list, fed to the geometric hover
    /// resolver. Zero until the first layout pass; the per-row fallback
    /// covers that window.
    @State private var actionListWidth: CGFloat = 0
    @FocusState private var renameFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The system wakes this view on minute boundaries while the
            // row is on screen — no timers, no polling while collapsed. The
            // age text and the spoken label both read the same tick.
            TimelineView(.everyMinute) { context in
                let text = BoardLayout.rowText(for: row, title: title, health: health, now: context.date)
                HStack(spacing: 0) {
                    Button(action: focus) {
                        mainRow(text, now: context.date).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(text.accessibilityLabel)
                    .help(text.help)
                    // The chevron sits beside — not inside — the focus button,
                    // so each click has exactly one unambiguous target.
                    chevronButton
                        .padding(.trailing, 12)
                }
            }
            // A right (or control) click also expands the actions inline;
            // the catcher passes every other event through.
            .overlay(RightClickCatcher(onRightClick: toggleActions))
            if isActionsExpanded {
                actionArea
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isActionsExpanded
                        ? Color.black.opacity(0.55)
                        : Color.white.opacity(isHovered ? 0.05 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            .white.opacity(isHovered || isActionsExpanded ? 0.12 : 0),
                            lineWidth: 0.5
                        )
                )
                .padding(.horizontal, 6)
        )
        .onHover { hovering in
            isHovered = hovering
            // Hovering a finished row fetches its recap lazily. It never
            // marks the row seen: only a click (store.focus) does that.
            if hovering, row.state == .doneUnseen {
                requestDetail()
            }
        }
        .onChange(of: isActionsExpanded) { _, _ in
            endRenameKeyboard()
            mode = .menu
        }
        // Each mode shows a different set of entries. The ones leaving cannot
        // be relied on to report their exit, so the selection starts empty and
        // the entry under the pointer re-announces itself as it appears.
        .onChange(of: mode) { _, _ in hoveredAction.clear() }
        .onDisappear { endRenameKeyboard() }
        // Lazy rows request branch data only while visible. Disappearance
        // cancels queued work through the coordinator; the menu-scoped cache
        // is discarded on close so a later open sees branch switches.
        .task(id: row.cwd) { [cwd = row.cwd] in
            branchName = nil
            guard let cwd else { return }
            let resolved = await branchCoordinator.branchName(forWorkingDirectory: cwd)
            guard !Task.isCancelled else { return }
            branchName = resolved
        }
        .accessibilityElement(children: .contain)
    }

    /// One line: the context line normally, the detail while hovered.
    private func secondaryText(_ text: BoardRowText) -> String {
        if isHovered, let question = row.detail?.question, !question.isEmpty {
            return question
        }
        return text.secondary
    }

    private func mainRow(_ text: BoardRowText, now: Date) -> some View {
        let secondary = secondaryText(text)
        return HStack(spacing: 8) {
            statusLight
                .frame(width: 11, height: 11)
            AgentIconView(source: row.source)
                .help(text.sourceHelp)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .layoutPriority(1)
            HStack(spacing: 3) {
                Text(secondary)
                    .font(.system(size: 11, design: .monospaced))
                    .truncationMode(.tail)
                if !(isHovered && row.detail != nil), let branch = branchName {
                    if !secondary.isEmpty {
                        Text("·")
                    }
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            Spacer(minLength: 8)
            Text(BoardLayout.ageText(for: row, now: now))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(.leading, SessionMenuLayout.sessionRowLeadingInset)
        .padding(.trailing, 10)
        .frame(height: SessionMenuLayout.sessionRowHeight)
        .opacity(BoardLayout.dimsRow(row, health: health) ? 0.45 : 1)
    }

    @ViewBuilder
    private var statusLight: some View {
        switch row.state.indicatorStyle {
        case .spinner:
            WorkingPixelSpinner()
        case .uncertain:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        case .greenDot, .orangeDot, .redDot, .mutedDot:
            Circle()
                .fill(indicatorColor(for: row.state.indicatorStyle))
                .frame(width: 8, height: 8)
        }
    }

    private var chevronButton: some View {
        Button(action: toggleActions) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered || isActionsExpanded ? 0.65 : 0.3))
                .rotationEffect(.degrees(isActionsExpanded ? 180 : 0))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(isActionsExpanded ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(title)")
    }

    /// Binds one action entry to the row's single hover selection. Every entry
    /// goes through here so the binding is written once.
    private func actionRow(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> ActionListRow {
        ActionListRow(
            label: label,
            systemImage: systemImage,
            isHovered: hoveredAction.hovered == label,
            setHovered: { hoveredAction.update(label, isHovered: $0) },
            action: action
        )
    }

    /// One source of order for the inline menu: the rows render from this
    /// array and the continuous-hover resolver indexes back into it, so the
    /// highlight can never disagree with the visible order. No entry ends the
    /// agent's process; the path actions need a working directory.
    private var menuActions: [InlineMenuAction] {
        var actions = [
            InlineMenuAction(label: "Rename", systemImage: "pencil", perform: beginRename),
        ]
        if let cwd = row.cwd {
            actions.append(InlineMenuAction(label: "Copy Project Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
                toggleActions()
            })
            actions.append(InlineMenuAction(label: "Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                toggleActions()
            })
        }
        return actions
    }

    @ViewBuilder
    private var actionArea: some View {
        switch mode {
        case .menu:
            menuActionList
                .transition(.opacity)
        case .renaming:
            // The field wears the same glass as the action rows — hairline
            // border over a whisper of light — and answers focus by waking
            // the hairline rather than growing chrome.
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    ZStack(alignment: .leading) {
                        // macOS does not honour styling on a TextField
                        // prompt, and the system placeholder colour sinks
                        // into the glass, so the prompt is drawn by hand
                        // and the field's own prompt is suppressed.
                        if renameDraft.isEmpty {
                            Text(row.title)
                                .foregroundStyle(.white.opacity(0.45))
                                .allowsHitTesting(false)
                        }
                        TextField(
                            "Agent name",
                            text: $renameDraft,
                            prompt: Text(verbatim: "")
                        )
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Agent name")
                        .foregroundStyle(.white.opacity(0.94))
                        .focused($renameFieldIsFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: SessionMenuLayout.actionRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(renameFieldIsFocused ? 0.08 : 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    .white.opacity(renameFieldIsFocused ? 0.22 : 0.1),
                                    lineWidth: 0.5
                                )
                        )
                )
                iconButton("checkmark", accessibilityLabel: "Save name", action: commitRename)
                iconButton("xmark", accessibilityLabel: "Cancel rename", action: cancelRename)
            }
            .padding(.horizontal, 2)
            .transition(.opacity)
        }
    }

    /// The list resolves its highlight geometrically on every pointer sample:
    /// per-row `.onHover` still runs as the fallback for a pointer that is
    /// already resting where a row appears, but any movement recomputes the
    /// selection from the pointer's position, so the highlight can never trail
    /// the pointer while the expansion spring is replacing tracking areas.
    private var menuActionList: some View {
        let actions = menuActions
        return VStack(spacing: SessionMenuLayout.actionRowSpacing) {
            ForEach(actions) { entry in
                actionRow(
                    entry.label,
                    systemImage: entry.systemImage,
                    action: entry.perform
                )
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { actionListWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in
                        actionListWidth = width
                    }
            }
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                guard let index = SessionMenuLayout.actionRowIndex(
                    x: location.x,
                    y: location.y,
                    listWidth: actionListWidth,
                    rowCount: actions.count
                ) else { return }
                // Samples arrive at pointer frequency; only a change in the
                // resolved entry may invalidate the view.
                let label = actions[index].label
                guard hoveredAction.hovered != label else { return }
                hoveredAction.update(label, isHovered: true)
            case .ended:
                guard hoveredAction.hovered != nil else { return }
                hoveredAction.clear()
            }
        }
    }

    /// Rename's confirm/cancel: circles cut from the same glass as the rows,
    /// sized against the field so the trio reads as one control.
    private func iconButton(
        _ systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction.hovered == accessibilityLabel
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.7))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.white.opacity(isHovered ? 0.13 : 0.06))
                        .overlay(
                            Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredAction.update(accessibilityLabel, isHovered: $0) }
        .accessibilityLabel(accessibilityLabel)
    }

    /// Sub-mode swaps cross-fade with the same spring the row opened with,
    /// so the area reads as one surface changing its mind rather than a
    /// hard cut between unrelated panels.
    private func switchMode(to newMode: ActionMode) {
        withAnimation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
        ) {
            mode = newMode
        }
    }

    private func beginRename() {
        renameDraft = renamePrefill
        switchMode(to: .renaming)
        // The panel refuses key status except during this edit; grant it
        // first, then focus the field once the window can accept it.
        setKeyboardFocus(true)
        DispatchQueue.main.async { renameFieldIsFocused = true }
    }

    private func commitRename() {
        rename(renameDraft)
        endRenameKeyboard()
        toggleActions()
    }

    private func cancelRename() {
        endRenameKeyboard()
        switchMode(to: .menu)
    }

    private func endRenameKeyboard() {
        guard mode == .renaming else { return }
        renameFieldIsFocused = false
        setKeyboardFocus(false)
    }
}

/// A menu entry of the inline action list, held as data so the rendered
/// order and the geometric hover resolver share one definition.
private struct InlineMenuAction: Identifiable {
    let label: String
    let systemImage: String
    let perform: () -> Void
    var id: String { label }
}

/// One entry of the inline action list: icon, label, hover highlight — the
/// look of a menu item, rendered inside the row instead of a floating menu.
private struct ActionListRow: View {
    let label: String
    let systemImage: String
    /// Hover is owned by the enclosing row's `HoverSelection`, not by a flag
    /// per entry: sibling flags disagree when a fast pointer makes AppKit
    /// deliver the hand-off out of order. `SessionRow.actionRow` binds these,
    /// and the list-level continuous hover overwrites them from geometry.
    let isHovered: Bool
    let setHovered: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(isHovered ? 0.95 : 0.8))
            .padding(.horizontal, 10)
            // The height feeds `SessionMenuLayout.actionRowIndex`; a literal
            // here would silently desynchronize the hover resolver.
            .frame(height: SessionMenuLayout.actionRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover(perform: setHovered)
        .accessibilityLabel(label)
    }
}

/// Claims right and control clicks for the inline action toggle and lets
/// every other event — left clicks, hover, scroll — fall through to the
/// SwiftUI row underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickForwardingView {
        let view = RightClickForwardingView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: RightClickForwardingView, context: Context) {
        view.onRightClick = onRightClick
    }
}

private final class RightClickForwardingView: NSView {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the trackpad spelling of a right click.
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)),
              InlineActionsClickGate.claimsPointer(
                  pressedMouseButtons: NSEvent.pressedMouseButtons,
                  controlKeyIsDown: NSEvent.modifierFlags.contains(.control)
              ) else {
            return nil
        }
        return self
    }
}
