import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A horizontal, side-by-side split of two panes with a draggable divider.
///
/// Resizing is **deferred**: while dragging, only a lightweight guide line
/// moves (smoothly, at any pixel), and the heavy panes/web views are resized
/// exactly once, on release. This avoids the ghosting/jitter that comes from
/// live-resizing a WKWebView every frame.
///
/// The guide snaps to 25%, 50% and 75% of the total width when dragged within a
/// small threshold of those positions.
struct SplitContainerView<Left: View, Right: View>: View {
    private let left: Left
    private let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left()
        self.right = right()
    }

    /// Committed fraction of the left pane, persisted across launches.
    @AppStorage("containerplus.splitFraction") private var storedFraction: Double = 0.5
    private var fraction: CGFloat { CGFloat(storedFraction) }
    /// Live fraction of the guide while dragging (nil when not dragging).
    @State private var dragFraction: CGFloat?
    @State private var dragStartFraction: CGFloat?
    @State private var isHoveringDivider = false

    private let snapPoints: [CGFloat] = [0.25, 0.50, 0.75]
    private let snapThreshold: CGFloat = 0.025
    private let dividerWidth: CGFloat = 10
    private let minFraction: CGFloat = 0.15
    private let maxFraction: CGFloat = 0.85

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let leftWidth = max(0, fraction * total - dividerWidth / 2)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    left
                        .frame(width: leftWidth)
                        .clipped()

                    divider(total: total)

                    right
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }

                // Smooth, cheap drag guide — no pane resizing until release.
                if let dragFraction {
                    guideLine
                        .position(x: dragFraction * total, y: geo.size.height / 2)
                        .frame(height: geo.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var guideLine: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Palette.separator)
                .frame(width: 1)

            Rectangle()
                .fill(isHoveringDivider || dragFraction != nil ? Color.accentColor.opacity(0.25) : Color.clear)
                .frame(width: dividerWidth)

            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Palette.tertiaryLabel)
                        .frame(width: 3, height: 3)
                }
            }
            .opacity(dragFraction == nil ? 1 : 0)
        }
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringDivider = hovering
            #if os(macOS)
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            #endif
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStartFraction ?? fraction
                    if dragStartFraction == nil { dragStartFraction = fraction }
                    dragFraction = snapped(clamp(start + value.translation.width / total))
                }
                .onEnded { _ in
                    if let dragFraction { storedFraction = Double(dragFraction) }
                    dragFraction = nil
                    dragStartFraction = nil
                }
        )
    }

    private func clamp(_ v: CGFloat) -> CGFloat {
        min(max(v, minFraction), maxFraction)
    }

    private func snapped(_ v: CGFloat) -> CGFloat {
        for point in snapPoints where abs(v - point) <= snapThreshold {
            return point
        }
        return v
    }
}
