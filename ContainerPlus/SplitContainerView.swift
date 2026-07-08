import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A horizontal, side-by-side split of two panes with a draggable divider.
///
/// The divider snaps to 25%, 50% and 75% of the total width when dragged
/// within a small threshold of those positions. (25% and 50% are the required
/// snap points; 75% is the mirror of 25% so the right pane snaps too.)
struct SplitContainerView<Left: View, Right: View>: View {
    private let left: Left
    private let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left()
        self.right = right()
    }

    /// Fraction of the total width given to the left pane.
    @State private var fraction: CGFloat = 0.5
    /// Fraction captured at the moment a drag begins.
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
            // Snap to whole points so the web views never render at sub-pixel
            // widths (which looks blurry / jittery while dragging).
            let leftWidth = max(0, (fraction * total - dividerWidth / 2).rounded())

            HStack(spacing: 0) {
                left
                    .frame(width: leftWidth)
                    .clipped()

                divider(total: total)

                right
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            // The divider drag drives layout directly; never implicitly animate
            // the width changes.
            .animation(nil, value: leftWidth)
        }
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Palette.separator)
                .frame(width: 1)

            Rectangle()
                .fill(isHoveringDivider ? Color.accentColor.opacity(0.25) : Color.clear)
                .frame(width: dividerWidth)

            // Grip dots for affordance.
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Palette.tertiaryLabel)
                        .frame(width: 3, height: 3)
                }
            }
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
                    let raw = start + value.translation.width / total
                    fraction = snapped(clamp(raw))
                }
                .onEnded { _ in
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
