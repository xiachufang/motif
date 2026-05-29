import SwiftUI

/// Shared style for icon-only buttons (SF Symbol labels); the text counterpart
/// is `MotifButtonStyle`, and the two share the same axis vocabulary:
/// - `role` fixes the color treatment — fill, stroke, ink.
/// - `size` fixes the circle's diameter and the symbol weight.
/// - `shadow` adds optional elevation.
///
/// Shape is always a circle (the analogue of the text style's capsule), and
/// press feedback is constant. The label is rendered icon-only, so you may
/// pass either a bare `Image(systemName:)` or a full `Label("Play", systemImage:)`
/// — only the symbol shows, while the title is kept for accessibility.
///
/// For a `Menu` label or any non-button view that should match an icon button,
/// use `.motifIconButtonLabel(role:size:)` — a `ButtonStyle` only applies to
/// buttons.
struct MotifIconButtonStyle: ButtonStyle {
    enum Role: Equatable {
        /// Accent fill + on-accent ink. High-emphasis. (≈ `.filled`)
        case filled
        /// Neutral fill + border stroke. Honors `isSelected`. (≈ `.bordered`)
        case bordered
        /// No fill or stroke; primary ink. Honors `isSelected`. (≈ `.plain`)
        case plain
    }

    enum Size: Equatable {
        case small   // 32
        case medium  // 40
        case large   // 48
        case xl      // 64
    }

    var role: Role = .bordered
    var size: Size = .medium
    /// Toggle affordance; `.bordered` and `.plain` react, promoting ink (and the
    /// border, for `.bordered`) to accent.
    var isSelected = false
    var shadow: MotifButtonShadow = .none

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .motifIconButtonLabel(role: role, size: size, isSelected: isSelected, shadow: shadow)
            .motifPressFeedback(isPressed: configuration.isPressed)
    }
}

extension View {
    /// Applies Motif icon-button chrome to any view so it matches
    /// `MotifIconButtonStyle` — use on `Menu` labels and other non-button
    /// views. Buttons should use `MotifIconButtonStyle` directly; it layers
    /// press feedback on top of this same chrome.
    func motifIconButtonLabel(
        role: MotifIconButtonStyle.Role = .bordered,
        size: MotifIconButtonStyle.Size = .medium,
        isSelected: Bool = false,
        shadow: MotifButtonShadow = .none
    ) -> some View {
        modifier(MotifIconButtonChrome(role: role, size: size, isSelected: isSelected, shadow: shadow))
    }
}

private struct MotifIconButtonChrome: ViewModifier {
    let role: MotifIconButtonStyle.Role
    let size: MotifIconButtonStyle.Size
    var isSelected = false
    var shadow: MotifButtonShadow = .none

    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(font)
            .foregroundStyle(foreground)
            .frame(width: dimension, height: dimension)
            .background(Circle().fill(fill))
            .overlay(stroke)
            .contentShape(Circle())
            .motifShadow(shadow.style)
    }

    private var foreground: Color {
        guard isEnabled else { return MotifTheme.textTertiary }
        switch role {
        case .filled:           return MotifTheme.textOnAccent
        case .bordered, .plain: return isSelected ? MotifTheme.accent : MotifTheme.textPrimary
        }
    }

    private var fill: Color {
        switch role {
        case .filled:   MotifTheme.accent
        // .bordered sits on either `background` or `surface`; a subtle tinted
        // fill is the only formulation that reads on both. Pure `surface`
        // (white in light mode) would disappear on a white card.
        case .bordered: MotifTheme.Fill.subtle
        case .plain:    MotifTheme.clear
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch role {
        case .filled, .plain:
            EmptyView()
        case .bordered:
            Circle().stroke(
                isSelected ? MotifTheme.accent : MotifTheme.border,
                lineWidth: MotifTheme.Stroke.hairline
            )
        }
    }

    private var dimension: CGFloat {
        switch size {
        case .small:  MotifTheme.Size.Control.sm
        case .medium: MotifTheme.Size.Control.md
        case .large:  MotifTheme.Size.Control.lg
        case .xl:     MotifTheme.Size.Control.xl
        }
    }

    private var font: Font {
        switch size {
        case .small, .medium: MotifTheme.Typography.icon(.small, weight: .bold)
        case .large:          MotifTheme.Typography.icon(.regular, weight: .bold)
        case .xl:             MotifTheme.Typography.icon(.medium, weight: .heavy)
        }
    }
}
