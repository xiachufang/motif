import SwiftUI

/// Design tokens for Motif. Single source of truth for color, type, spacing,
/// radius, elevation, and interaction-state values.
///
/// Token tiers (see reference/design-tokens.md):
/// - Colors are semantic (`accent`, `textPrimary`, `surface`) and bound to the
///   asset catalog — the asset catalog is the primitive/palette layer.
/// - `Spacing` / `Radius` are generic abstract scales (t-shirt sizes).
/// - `Size` holds component-scoped sizes, grouped by domain (`Size.Control`).
/// - `State` groups interaction-state values so a press affordance reads as one
///   thing instead of being split across opacity / scale / duration buckets.
enum MotifTheme {
    static let accent = Color("MotifAccent")
    static let accentContainer = Color("MotifAccentContainer")
    static let background = Color("MotifBackground")
    static let surface = Color("MotifSurface")
    static let surfaceElevated = Color("MotifSurfaceElevated")
    static let surfaceTranslucent = Color("MotifSurfaceTranslucent")
    static let border = Color("MotifBorder")
    static let borderStrong = Color("MotifBorderStrong")
    static let textPrimary = Color("MotifTextPrimary")
    static let textSecondary = Color("MotifTextSecondary")
    static let textTertiary = Color("MotifTextTertiary")
    static let textOnAccent = Color("MotifTextOnAccent")
    static let danger = Color("MotifDanger")
    /// Transparent. A primitive, not an asset — used for "no fill" / empty shadows.
    static let clear = Color.clear
    static let shadow = Color("MotifShadow")

    enum Typography {
        // Apple HIG text styles with their SYSTEM-DEFAULT weights — almost all
        // are regular; only `headline` is Apple's semibold default. Where the
        // curated size matches Apple's, use `Font.<style>` directly so Dynamic
        // Type scaling works automatically; where the size diverges, fall back
        // to `Font.system(size:)` and lose Dynamic Type for that tier.
        //
        // Weight is a call-site axis: add `.bold()` / `.weight(.heavy)` only at
        // the specific spots that need emphasis.
        static let largeTitle = Font.largeTitle           // 34 regular, Dynamic Type
        static let title = Font.system(size: 26)          // custom (Apple title=28), regular
        static let title2 = Font.title2                   // 22 regular, Dynamic Type
        static let headline = Font.headline               // 17 semibold (Apple default), Dynamic Type
        static let callout = Font.callout                 // 16 regular, Dynamic Type
        static let subheadline = Font.subheadline         // 15 regular, Dynamic Type
        /// 15pt body text. Same render as `subheadline` after weight-strip —
        /// kept as a distinct role; add `.weight(...)` at call sites to differ.
        static let body = Font.system(size: 15)           // custom (Apple body=17), regular
        /// Apple-missing 14pt tier — a step below `body`.
        static let body2 = Font.system(size: 14)          // regular
        static let footnote = Font.footnote               // 13 regular, Dynamic Type
        static let caption = Font.caption                 // 12 regular, Dynamic Type
        /// 11pt eyebrow/kicker labels (use with `caption2Tracking`); add
        /// `.weight(.heavy)` at the call site for the small-caps look.
        static let caption2 = Font.caption2               // 11 regular, Dynamic Type

        static let caption2Tracking: CGFloat = 2

        enum IconScale {
            case small, regular, medium, large, brand

            var value: CGFloat {
                switch self {
                case .small: 16
                case .regular: 18
                case .medium: 22
                case .large: 28
                case .brand: 64
                }
            }
        }

        static func icon(_ scale: IconScale = .regular, weight: Font.Weight = .regular) -> Font {
            Font.system(size: scale.value, weight: weight)
        }

        static func symbol(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.system(size: size, weight: weight)
        }
    }

    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let focus: CGFloat = 1.5
    }

    enum Spacing {
        static let none: CGFloat = 0
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
    }

    /// Component-scoped sizes (Tier-3 tokens), grouped by the component domain
    /// they belong to. Generic spacing/radius live in `Spacing` / `Radius`.
    enum Size {
        /// Square control diameters (icon buttons) and text-button heights.
        enum Control {
            static let sm: CGFloat = 32
            static let md: CGFloat = 40
            static let lg: CGFloat = 48
            static let xl: CGFloat = 64
        }
    }

    /// Interaction-state tokens, grouped so the press affordance reads as one
    /// thing instead of being split across opacity / scale / duration buckets.
    enum State {
        static let pressedOpacity = 0.72
        static let pressedScale: CGFloat = 0.96
        static let pressDuration = 0.16
    }

    enum Opacity {
        static let hidden = 0.0
        static let disabled = 0.45
        static let textHighlight = 0.20
    }

    /// Subtle translucent fills for chrome that sits ON TOP of `background` or
    /// `surface` (pills, capsule tabs, sticky modifiers, input pills). These
    /// are NOT cards — for raised content surfaces use `surface` /
    /// `surfaceElevated`. The `textPrimary.opacity(...)` formulation reads as
    /// a tinted grey on both light (grey canvas) and dark backgrounds, where
    /// a hard-coded grey would have to invert per-mode.
    enum Fill {
        static var subtle: Color { textPrimary.opacity(0.06) }
        static var pressed: Color { textPrimary.opacity(0.15) }
    }

    struct ShadowStyle {
        let color: Color
        let opacity: Double
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        init(color: Color, opacity: Double, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
            self.color = color
            self.opacity = opacity
            self.radius = radius
            self.x = x
            self.y = y
        }
    }

    /// Elevation presets. Each carries its own opacity — shadow opacities are a
    /// component concern, so they live here rather than polluting `Opacity`.
    enum Shadows {
        static let none = ShadowStyle(
            color: MotifTheme.clear,
            opacity: Opacity.hidden,
            radius: Spacing.none,
            y: Spacing.none
        )
        static let dock = ShadowStyle(
            color: MotifTheme.shadow,
            opacity: 0.35,
            radius: 20,
            y: 10
        )
        static let card = ShadowStyle(
            color: MotifTheme.shadow,
            opacity: 0.40,
            radius: 28,
            y: 14
        )
        static let primaryButton = ShadowStyle(
            color: MotifTheme.accent,
            opacity: 0.65,
            radius: 28,
            y: 12
        )
        static let accentControl = ShadowStyle(
            color: MotifTheme.accent,
            opacity: 0.45,
            radius: 18,
            y: 8
        )
    }

    static func highlightedTextBackground() -> Color {
        accent.opacity(Opacity.textHighlight)
    }
}

extension View {
    func motifShadow(_ style: MotifTheme.ShadowStyle) -> some View {
        shadow(
            color: style.color.opacity(style.opacity),
            radius: style.radius,
            x: style.x,
            y: style.y
        )
    }

    /// Shared press/disabled feedback for the button styles: dims on press,
    /// dims further when disabled, and eases the scale down on the common press
    /// timing. Feed `configuration.isPressed` from a `ButtonStyle`.
    func motifPressFeedback(isPressed: Bool) -> some View {
        modifier(MotifPressFeedback(isPressed: isPressed))
    }
}

private struct MotifPressFeedback: ViewModifier {
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? (isPressed ? MotifTheme.State.pressedOpacity : 1) : MotifTheme.Opacity.disabled)
            .scaleEffect(isPressed ? MotifTheme.State.pressedScale : 1)
            .animation(.snappy(duration: MotifTheme.State.pressDuration), value: isPressed)
    }
}
