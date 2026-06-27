/// Motif design system, ported from `apps/ios/Motif/UI/MotifTheme.swift`.
///
/// Semantic color tokens live in a [MotifColors] [ThemeExtension] (light + dark
/// variants); spacing/radius/control-size scales are plain constants. Use
/// `Theme.of(context).extension<MotifColors>()!` (or the `context.motif`
/// helper) to read colors.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransition;
import 'package:flutter/material.dart';

/// Spacing scale (T-shirt sizes).
abstract final class MotifSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
}

/// Corner radii.
abstract final class MotifRadius {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;

  /// Fully rounded (capsule/pill). Use instead of magic `circular(999)`.
  static const double pill = 999;
}

/// Square control diameters / button heights.
abstract final class MotifControlSize {
  static const double sm = 32;
  static const double md = 40;
  static const double lg = 48;
  static const double xl = 64;
}

/// Icon glyph sizes. Snap all `Icon(size:)` to one of these.
abstract final class MotifIconSize {
  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
}

/// Semantic type scale. Styles carry **no color** — apply one with
/// `MotifType.body.copyWith(color: c.textPrimary)`. This is the single source
/// of truth for font size/weight; avoid inline `TextStyle(fontSize:)`.
abstract final class MotifType {
  /// Large headline (welcome / hero titles).
  static const display = TextStyle(fontSize: 22, fontWeight: FontWeight.w700);

  /// Screen / dialog / nav-bar titles.
  static const title = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);

  /// Emphasized row/section titles.
  static const headline = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

  /// Primary body and list-row titles.
  static const body = TextStyle(fontSize: 15, fontWeight: FontWeight.w400);

  /// Buttons, chips, and other interactive labels.
  static const callout = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);

  /// Subtitles and secondary supporting text.
  static const subhead = TextStyle(fontSize: 13, fontWeight: FontWeight.w400);

  /// Uppercase group headers.
  static const overline = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
  );

  /// Metadata / timestamps / counts.
  static const caption = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);

  /// Smallest annotations.
  static const micro = TextStyle(fontSize: 11, fontWeight: FontWeight.w500);

  /// Monospaced (paths, code, diff body).
  static const mono = TextStyle(fontSize: 13, fontFamily: 'monospace');
  static const monoSmall = TextStyle(fontSize: 12, fontFamily: 'monospace');
}

/// Elevation as shadow tuples, built from the theme's shadow color. Replaces
/// the ad-hoc `BoxShadow` literals scattered across floating surfaces.
abstract final class MotifElevation {
  /// Resting cards / subtle lift.
  static List<BoxShadow> card(Color shadow) => [
    BoxShadow(
      color: shadow.withValues(alpha: 0.08),
      blurRadius: 12,
      offset: const Offset(0, 3),
    ),
  ];

  /// Floating overlays: toasts, banners, menus, the reconnect banner.
  static List<BoxShadow> overlay(Color shadow) => [
    BoxShadow(
      color: shadow.withValues(alpha: 0.12),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];
}

/// Semantic colors. Values transcribed from the iOS asset catalog colorsets.
@immutable
class MotifColors extends ThemeExtension<MotifColors> {
  final Color accent;
  final Color accentContainer;
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceTranslucent;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textOnAccent;
  final Color danger;
  final Color success;
  final Color warning;
  final Color shadow;

  const MotifColors({
    required this.accent,
    required this.accentContainer,
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceTranslucent,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textOnAccent,
    required this.danger,
    required this.success,
    required this.warning,
    required this.shadow,
  });

  Color get subtleFill => textPrimary.withValues(alpha: 0.06);
  Color accentFill([double alpha = 0.18]) => accent.withValues(alpha: alpha);

  static const light = MotifColors(
    // Slate-blue identity kept, nudged slightly more saturated/brighter.
    accent: Color(0xFF36679B),
    accentContainer: Color(0xFFD6E1EE),
    background: Color(0xFFF2F2F0),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceTranslucent: Color(0xA6FFFFFF),
    border: Color(0xFFE5E5E2),
    borderStrong: Color(0xFFC8C8C4),
    textPrimary: Color(0xFF1A1A18),
    textSecondary: Color(0xFF4A4A48),
    // Darkened from 0xFF888884 to clear WCAG AA for small text on background.
    textTertiary: Color(0xFF6E6E6A),
    textOnAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFD6453E),
    success: Color(0xFF2F8C4C),
    warning: Color(0xFFC47A00),
    shadow: Color(0xFF000000),
  );

  static const dark = MotifColors(
    // Slate-blue identity kept, nudged slightly more saturated.
    accent: Color(0xFF6FA3D6),
    accentContainer: Color(0xFF1F2C3F),
    background: Color(0xFF0E1013),
    surface: Color(0xFF1C1F25),
    surfaceElevated: Color(0xFF262A31),
    surfaceTranslucent: Color(0xA60E1013),
    border: Color(0xFF2A2E33),
    borderStrong: Color(0xFF3D424A),
    textPrimary: Color(0xFFF5F5F2),
    textSecondary: Color(0xFFB5B5B0),
    // Lightened from 0xFF7B7B76 to clear WCAG AA for small text on surfaces.
    textTertiary: Color(0xFF8E8E88),
    textOnAccent: Color(0xFF0F172A),
    danger: Color(0xFFFF6A60),
    success: Color(0xFF68C47A),
    warning: Color(0xFFFFB85C),
    shadow: Color(0xFF000000),
  );

  @override
  MotifColors copyWith({
    Color? accent,
    Color? accentContainer,
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceTranslucent,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textOnAccent,
    Color? danger,
    Color? success,
    Color? warning,
    Color? shadow,
  }) => MotifColors(
    accent: accent ?? this.accent,
    accentContainer: accentContainer ?? this.accentContainer,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    surfaceTranslucent: surfaceTranslucent ?? this.surfaceTranslucent,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    textOnAccent: textOnAccent ?? this.textOnAccent,
    danger: danger ?? this.danger,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    shadow: shadow ?? this.shadow,
  );

  @override
  MotifColors lerp(covariant MotifColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return MotifColors(
      accent: c(accent, other.accent),
      accentContainer: c(accentContainer, other.accentContainer),
      background: c(background, other.background),
      surface: c(surface, other.surface),
      surfaceElevated: c(surfaceElevated, other.surfaceElevated),
      surfaceTranslucent: c(surfaceTranslucent, other.surfaceTranslucent),
      border: c(border, other.border),
      borderStrong: c(borderStrong, other.borderStrong),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textTertiary: c(textTertiary, other.textTertiary),
      textOnAccent: c(textOnAccent, other.textOnAccent),
      danger: c(danger, other.danger),
      success: c(success, other.success),
      warning: c(warning, other.warning),
      shadow: c(shadow, other.shadow),
    );
  }
}

extension MotifThemeContext on BuildContext {
  MotifColors get motif => Theme.of(this).extension<MotifColors>()!;

  /// Merges custom colors onto [IconButtonTheme] without [IconButton.styleFrom],
  /// which regenerates hover/press overlays from [foregroundColor].
  ButtonStyle iconButtonStyle({
    Color? foregroundColor,
    Color? backgroundColor,
    Size? fixedSize,
    Size? minimumSize,
    EdgeInsetsGeometry? padding,
  }) {
    return (IconButtonTheme.of(this).style ?? const ButtonStyle()).copyWith(
      foregroundColor: foregroundColor == null
          ? null
          : WidgetStatePropertyAll(foregroundColor),
      backgroundColor: backgroundColor == null
          ? null
          : WidgetStatePropertyAll(backgroundColor),
      fixedSize: fixedSize == null ? null : WidgetStatePropertyAll(fixedSize),
      minimumSize: minimumSize == null
          ? null
          : WidgetStatePropertyAll(minimumSize),
      padding: padding == null ? null : WidgetStatePropertyAll(padding),
    );
  }
}

/// Single source of truth for "no M3 state-layer overlay" — the transparent
/// `overlayColor` shared by every interactive component theme (buttons,
/// selection controls, tab bar, slider) so hover/press feedback removal is
/// uniform rather than re-declared inline per theme.
const WidgetStateProperty<Color?> kMotifNoOverlay = WidgetStatePropertyAll(
  Colors.transparent,
);

/// Disables Material hover/press/splash overlays when merged onto a [ButtonStyle].
const ButtonStyle motifNoButtonFeedback = ButtonStyle(
  overlayColor: kMotifNoOverlay,
  splashFactory: NoSplash.splashFactory,
);

extension MotifButtonStyleMerge on ButtonStyle {
  ButtonStyle withoutFeedback() => merge(motifNoButtonFeedback);
}

/// Builds the [ThemeData] for a given brightness with the Motif palette.
ThemeData motifTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark
      ? MotifColors.dark
      : MotifColors.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: colors.accent,
        brightness: brightness,
        primary: colors.accent,
        onPrimary: colors.textOnAccent,
        surface: colors.surface,
        error: colors.danger,
      ).copyWith(
        primary: colors.accent,
        onPrimary: colors.textOnAccent,
        primaryContainer: colors.accentContainer,
        onPrimaryContainer: colors.accent,
        secondary: colors.accent,
        onSecondary: colors.textOnAccent,
        secondaryContainer: colors.accentContainer,
        onSecondaryContainer: colors.accent,
        tertiary: colors.accent,
        onTertiary: colors.textOnAccent,
        tertiaryContainer: colors.accentContainer,
        onTertiaryContainer: colors.accent,
        surface: colors.surface,
        onSurface: colors.textPrimary,
        surfaceContainerLowest: colors.background,
        surfaceContainerLow: colors.surface,
        surfaceContainer: colors.surface,
        surfaceContainerHigh: colors.surfaceElevated,
        surfaceContainerHighest: colors.surfaceElevated,
        surfaceTint: Colors.transparent,
        error: colors.danger,
        onError: colors.textOnAccent,
        outline: colors.border,
        outlineVariant: colors.borderStrong,
        shadow: colors.shadow,
        scrim: colors.shadow,
        inverseSurface: colors.textPrimary,
        onInverseSurface: colors.background,
        inversePrimary: colors.accent,
      );
  final textTheme = Typography.material2021().black.apply(
    bodyColor: colors.textPrimary,
    displayColor: colors.textPrimary,
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(MotifRadius.lg),
    borderSide: BorderSide(color: colors.border),
  );
  final roundedControlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(MotifRadius.sm),
  );
  // overlayColor MUST be passed into styleFrom (not merged afterward via
  // withoutFeedback). styleFrom only honors an explicitly transparent
  // overlayColor; otherwise it GENERATES a non-transparent overlay from
  // foregroundColor, and a later merge can't override that non-null value
  // (ButtonStyle.merge keeps the receiver's field). So set it here directly.
  final textButtonStyle = TextButton.styleFrom(
    foregroundColor: colors.accent,
    disabledForegroundColor: colors.textTertiary,
    shape: roundedControlShape,
    overlayColor: Colors.transparent,
  );
  final filledButtonStyle = FilledButton.styleFrom(
    backgroundColor: colors.accent,
    foregroundColor: colors.textOnAccent,
    disabledBackgroundColor: colors.subtleFill,
    disabledForegroundColor: colors.textTertiary,
    shape: roundedControlShape,
    overlayColor: Colors.transparent,
  );
  final outlinedButtonStyle = OutlinedButton.styleFrom(
    foregroundColor: colors.textPrimary,
    disabledForegroundColor: colors.textTertiary,
    side: BorderSide(color: colors.border),
    shape: roundedControlShape,
    overlayColor: Colors.transparent,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    // Keep every platform's default page-transition animation, but on macOS
    // (whose default is Cupertino) swap in a builder that runs the same
    // Cupertino slide WITHOUT the edge/trackpad swipe-back gesture. Other
    // platforms (incl. iOS's native swipe-back) are left at their defaults.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        ...const PageTransitionsTheme().builders,
        TargetPlatform.macOS: const _NoSwipeCupertinoPageTransitionsBuilder(),
      },
    ),
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.background,
    extensions: [colors],
    fontFamily: null,
    splashFactory: NoSplash.splashFactory,
    hoverColor: Colors.transparent,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: colors.background,
      // Actions sit flush at the edge (default actionsPadding is zero); our
      // 40px icon buttons hold a 20px glyph, so the icon's optical inset is
      // (40-20)/2 = 10px — tighter than the 16px (lg) titleSpacing/body inset.
      // Nudge actions in by 6px so the trailing icon also lands at 16px.
      actionsPadding: const EdgeInsets.only(right: MotifSpacing.xs),
      // Intentionally NOT setting foregroundColor. When it is set, AppBar sees a
      // non-default actions icon color and rebuilds the action IconButtons'
      // style via IconButton.styleFrom — which regenerates a (non-transparent)
      // overlayColor from the foreground, re-adding the hover/press circle that
      // our iconButtonTheme disables. Leaving it null keeps AppBar on the path
      // that preserves our transparent overlay. Icon color still comes from
      // iconButtonTheme (textPrimary == colorScheme.onSurface, the default
      // foreground), and the title from titleTextStyle below — so nothing
      // changes visually except the unwanted overlay disappears.
      centerTitle: false,
      titleTextStyle: MotifType.title.copyWith(color: colors.textPrimary),
    ),
    dividerTheme: DividerThemeData(color: colors.border, thickness: 1),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return colors.textTertiary;
          return colors.textPrimary;
        }),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: kMotifNoOverlay,
        iconSize: WidgetStateProperty.all(20),
        shape: WidgetStateProperty.all(const CircleBorder()),
        minimumSize: WidgetStateProperty.all(
          const Size.square(MotifControlSize.md),
        ),
        fixedSize: WidgetStateProperty.all(
          const Size.square(MotifControlSize.md),
        ),
        padding: WidgetStateProperty.all(EdgeInsets.zero),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.textSecondary,
      selectedColor: colors.accent,
      selectedTileColor: colors.accentFill(0.12),
      textColor: colors.textPrimary,
      titleTextStyle: MotifType.body.copyWith(color: colors.textPrimary),
      subtitleTextStyle: MotifType.caption.copyWith(color: colors.textTertiary),
      leadingAndTrailingTextStyle: MotifType.caption.copyWith(
        color: colors.textTertiary,
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: textButtonStyle),
    filledButtonTheme: FilledButtonThemeData(style: filledButtonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedButtonStyle),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: ButtonStyle(
        overlayColor: kMotifNoOverlay,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      highlightElevation: 0,
      backgroundColor: colors.accent,
      foregroundColor: colors.textOnAccent,
      shape: const CircleBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.subtleFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: inputBorder,
      enabledBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: colors.accent, width: 1.5),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: colors.danger),
      ),
      labelStyle: TextStyle(color: colors.textSecondary),
      hintStyle: TextStyle(color: colors.textTertiary),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MotifRadius.lg),
      ),
      titleTextStyle: MotifType.title.copyWith(color: colors.textPrimary),
      contentTextStyle: MotifType.subhead.copyWith(color: colors.textSecondary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.shadow.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MotifRadius.sm),
        side: BorderSide(color: colors.border),
      ),
      textStyle: MotifType.body.copyWith(color: colors.textPrimary),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return MotifType.body.copyWith(color: colors.textTertiary);
        }
        return MotifType.body.copyWith(color: colors.textPrimary);
      }),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(colors.surfaceElevated),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shadowColor: WidgetStateProperty.all(
          colors.shadow.withValues(alpha: 0.18),
        ),
        shape: WidgetStateProperty.all(roundedControlShape),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return colors.textTertiary;
          return colors.textPrimary;
        }),
        overlayColor: kMotifNoOverlay,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MotifRadius.xl),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.surfaceElevated,
      contentTextStyle: TextStyle(color: colors.textPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MotifRadius.sm),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.textPrimary,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      textStyle: MotifType.caption.copyWith(color: colors.background),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return colors.textTertiary;
        if (states.contains(WidgetState.selected)) return colors.textOnAccent;
        return colors.textSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return colors.subtleFill;
        if (states.contains(WidgetState.selected)) return colors.accent;
        return colors.subtleFill;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return colors.accent;
        return colors.border;
      }),
      overlayColor: kMotifNoOverlay,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return colors.subtleFill;
        if (states.contains(WidgetState.selected)) return colors.accent;
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(colors.textOnAccent),
      side: BorderSide(color: colors.borderStrong),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      overlayColor: kMotifNoOverlay,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return colors.textTertiary;
        if (states.contains(WidgetState.selected)) return colors.accent;
        return colors.textSecondary;
      }),
      overlayColor: kMotifNoOverlay,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: colors.accent,
      inactiveTrackColor: colors.subtleFill,
      thumbColor: colors.accent,
      overlayColor: Colors.transparent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.accent,
      linearTrackColor: colors.subtleFill,
      circularTrackColor: colors.subtleFill,
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.shadow.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MotifRadius.sm),
        side: BorderSide(color: colors.border),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: colors.border,
      indicatorColor: colors.accent,
      labelColor: colors.accent,
      unselectedLabelColor: colors.textSecondary,
      overlayColor: kMotifNoOverlay,
    ),
  );
}

/// The macOS Cupertino page-slide animation, **without** the back-swipe gesture.
///
/// The stock [CupertinoPageTransitionsBuilder] delegates to the Cupertino route
/// mixin, which wraps the page in a `_CupertinoBackGestureDetector` (the
/// edge/trackpad swipe-back). This builder renders the identical slide via the
/// public [CupertinoPageTransition] widget but omits that detector, so the
/// transition looks the same while the desktop swipe-back is disabled.
/// `linearTransition` is `false` — the curved (non-gesture) animation, which is
/// exactly what the stock builder uses when no pop gesture is in flight.
class _NoSwipeCupertinoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoSwipeCupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: false,
      child: child,
    );
  }
}
