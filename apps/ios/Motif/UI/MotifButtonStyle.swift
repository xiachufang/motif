import SwiftUI

/// Drop shadow applied by the Motif button styles. Shared by the text and
/// icon styles so the elevation vocabulary stays consistent.
enum MotifButtonShadow: Equatable {
    case none
    /// Neutral drop shadow for an elevated, high-emphasis control.
    case drop
    /// Accent-tinted glow for a floating control.
    case glow

    var style: MotifTheme.ShadowStyle {
        switch self {
        case .none: MotifTheme.Shadows.none
        case .drop: MotifTheme.Shadows.primaryButton
        case .glow: MotifTheme.Shadows.accentControl
        }
    }
}

/// Shared style for text / label buttons; the icon-only counterpart is
/// `MotifIconButtonStyle`. Composed from independent axes:
/// - `role` fixes the color treatment — fill, stroke, ink.
/// - `size` fixes the height and horizontal padding.
/// - `shadow` adds optional elevation.
///
/// Shape (capsule), font, and the press feedback are constant. Role names
/// mirror `UIButton.Configuration`. For a `Menu` label or any non-button view
/// that should match a button, use the `.motifButtonLabel(role:size:)`
/// modifier instead — a `ButtonStyle` only applies to buttons.
struct MotifButtonStyle: ButtonStyle {
    enum Role: Equatable {
        /// Accent fill + on-accent ink. High-emphasis primary action. (≈ `.filled`)
        case filled
        /// Neutral fill + accent ink, no stroke. Medium emphasis. (≈ `.tinted`)
        case tinted
        /// Neutral fill + border stroke. Low emphasis; honors `isSelected`. (≈ `.bordered`)
        case bordered
        /// No fill or stroke; primary ink. Lowest emphasis; honors `isSelected`. (≈ `.plain`)
        case plain
    }

    enum Size: Equatable {
        case small
        case medium
        case large
    }

    var role: Role = .filled
    var size: Size = .large
    /// Toggle affordance; `.bordered` and `.plain` react, promoting ink (and the
    /// border, for `.bordered`) to accent.
    var isSelected = false
    var shadow: MotifButtonShadow = .none

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .motifButtonLabel(role: role, size: size, isSelected: isSelected, shadow: shadow)
            .motifPressFeedback(isPressed: configuration.isPressed)
    }
}

extension View {
    /// Applies Motif button chrome to any view so it matches
    /// `MotifButtonStyle` — use on `Menu` labels and other non-button views.
    /// Buttons and `ShareLink` should use `MotifButtonStyle` directly; it
    /// layers press feedback on top of this same chrome.
    func motifButtonLabel(
        role: MotifButtonStyle.Role = .filled,
        size: MotifButtonStyle.Size = .large,
        isSelected: Bool = false,
        shadow: MotifButtonShadow = .none
    ) -> some View {
        modifier(MotifButtonChrome(role: role, size: size, isSelected: isSelected, shadow: shadow))
    }
}

private struct MotifButtonChrome: ViewModifier {
    let role: MotifButtonStyle.Role
    let size: MotifButtonStyle.Size
    var isSelected = false
    var shadow: MotifButtonShadow = .none

    func body(content: Content) -> some View {
        content
            .font(MotifTheme.Typography.footnote.bold())
            .foregroundStyle(foreground)
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
            .background(fill, in: shape)
            .overlay(stroke)
            .motifShadow(shadow.style)
    }

    private var shape: Capsule { Capsule(style: .continuous) }

    private var foreground: Color {
        switch role {
        case .filled:           MotifTheme.textOnAccent
        case .tinted:           MotifTheme.accent
        case .bordered, .plain: isSelected ? MotifTheme.accent : MotifTheme.textPrimary
        }
    }

    private var fill: Color {
        switch role {
        case .filled:   MotifTheme.accent
        // .tinted = neutral fill + accent ink. `accentContainer` is the
        // tonal pair of `accent` and is exactly what UIButton's `.tinted`
        // configuration paints.
        case .tinted:   MotifTheme.accentContainer
        // .bordered sits on either `background` or `surface`; Fill.subtle
        // reads on both. Pure `surface` (white in light) disappears on a
        // white card.
        case .bordered: MotifTheme.Fill.subtle
        case .plain:    MotifTheme.clear
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch role {
        case .filled, .tinted, .plain:
            EmptyView()
        case .bordered:
            shape.stroke(
                isSelected ? MotifTheme.accent : MotifTheme.border,
                lineWidth: MotifTheme.Stroke.hairline
            )
        }
    }

    private var height: CGFloat {
        switch size {
        case .small:  MotifTheme.Size.Control.sm
        case .medium: MotifTheme.Size.Control.md
        case .large:  MotifTheme.Size.Control.lg
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small:          MotifTheme.Spacing.md
        case .medium, .large: MotifTheme.Spacing.lg
        }
    }
}
