import SwiftUI

// MARK: - Waveform indicator

/// Three vertical capsules that animate continuously while shown, with
/// the upstream RMS `level` modulating amplitude. The continuous
/// baseline is deliberate: DoubaoASR's `onAudioLevel` is silently 0 in
/// some input-format paths (notably the iOS Simulator's input node,
/// which doesn't expose `floatChannelData`), so a purely level-driven
/// indicator looks frozen even when ASR is actively transcribing.
/// Baseline sine = "I'm listening"; level overlay = "I hear you".
///
/// `internal` (not `private`) because `BottomInputBar`'s mic button lives in
/// a separate file.
struct WaveformIndicator: View {
    let level: Float

    var body: some View {
        let clampedLevel = Double(max(0, min(level, 1)))
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                bar(phase: 0.0, t: t, level: clampedLevel)
                bar(phase: 0.7, t: t, level: clampedLevel)
                bar(phase: 1.4, t: t, level: clampedLevel)
            }
        }
        .accessibilityHidden(true)
    }

    private func bar(phase: Double, t: Double, level: Double) -> some View {
        // Baseline ~0.35..0.65 idle pulse; level adds up to 0.35 more
        // with a faster wobble. Clamped to [0.2, 1.0] so the bars never
        // disappear entirely.
        let baseline = 0.5 + 0.15 * sin(t * 3.5 + phase)
        let overlay  = level * (0.5 + 0.5 * sin(t * 11 + phase * 1.7)) * 0.35
        let scale = max(0.2, min(1.0, baseline + overlay))
        return Capsule()
            .fill(MotifTheme.accent)
            .frame(width: 3)
            .scaleEffect(y: CGFloat(scale), anchor: .center)
    }
}

// MARK: - Symbol effect shim

private extension View {
    /// Apply a pulsing symbol effect on iOS 17+; no-op on older builds.
    /// Gives the mic a "yes I'm hot" subtle breathing while recording
    /// without a `#available` block at every call site.
    @ViewBuilder
    func symbolEffectIfAvailable(pulsing: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.pulse, options: .repeating, isActive: pulsing)
        } else {
            self
        }
    }
}

// MARK: - Quick command row

/// Uniform content height for every quick-command strip button so icon-only
/// and text buttons (which have different intrinsic heights) end up the same
/// capsule height. Padding is added around this on top — together they make a
/// comfortably tappable (~44pt) target.
private let qcContentHeight: CGFloat = 22

struct QuickCommandRow: View {
    let commands: [QuickCommand]
    let disabled: Bool
    let ctrlState: StickyState
    let altState: StickyState
    let shiftState: StickyState
    let onTap: (QuickCommand) -> Void
    let onToggleModifier: (ModifierKind) -> Void
    let onEdit: () -> Void

    var body: some View {
        // Ctrl / Alt / Shift are ordinary list entries now (kind .ctrl /
        // .alt / .shift), rendered as sticky-modifier buttons wherever the
        // user placed them. Everything else is a normal quick-command capsule.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(commands) { cmd in
                    switch cmd.kind {
                    case .ctrl:
                        StickyModifierButton(label: cmd.label, symbol: cmd.symbol ?? "control", state: ctrlState) {
                            onToggleModifier(.ctrl)
                        }
                        .disabled(disabled)
                    case .alt:
                        StickyModifierButton(label: cmd.label, symbol: cmd.symbol ?? "option", state: altState) {
                            onToggleModifier(.alt)
                        }
                        .disabled(disabled)
                    case .shift:
                        StickyModifierButton(label: cmd.label, symbol: cmd.symbol ?? "shift", state: shiftState) {
                            onToggleModifier(.shift)
                        }
                        .disabled(disabled)
                    default:
                        QuickCommandButton(repeatEnabled: repeatEnabled(for: cmd)) {
                            onTap(cmd)
                        } label: {
                            label(for: cmd)
                        }
                        .disabled(disabled)
                    }
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(MotifTheme.Typography.callout)
                        .frame(height: qcContentHeight)
                        .padding(.horizontal, MotifTheme.Spacing.md).padding(.vertical, 9)
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(MotifTheme.textSecondary)
            }
            .padding(.horizontal, MotifTheme.Spacing.md)
            .padding(.vertical, MotifTheme.Spacing.sm)
        }
    }

    /// No sticky Ctrl/Alt/Shift currently armed or locked. Auto-repeat is only
    /// offered in this state — a modifier is consumed by the first key press,
    /// so repeating a modified key isn't meaningful.
    private var noStickyModifier: Bool {
        ctrlState == .inactive && altState == .inactive && shiftState == .inactive
    }

    /// Hold-to-repeat applies to immediate "key" commands (arrows, Esc, ^C,
    /// function keys) with no baked-in or armed modifier — not to snippet
    /// inserts, paste, or the directory picker.
    private func repeatEnabled(for cmd: QuickCommand) -> Bool {
        cmd.kind == .bytes && cmd.sendImmediately && cmd.modifiers.isEmpty && noStickyModifier
    }

    @ViewBuilder
    private func label(for cmd: QuickCommand) -> some View {
        // Baked-in modifiers render as a ⌃⌥⇧ prefix so a "Ctrl+Alt+Del"
        // button reads as such at a glance, whether it's symbol- or text-based.
        let glyphs = cmd.modifiers.glyphs
        HStack(spacing: 2) {
            if !glyphs.isEmpty {
                Text(glyphs)
                    .font(MotifTheme.Typography.callout.monospaced())
            }
            // Symbol-only when a glyph is set; fall back to the text label for
            // commands without one (Esc, ^C, snippets, …).
            if let symbol = cmd.symbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(MotifTheme.Typography.callout)
            } else {
                Text(cmd.label)
                    .font(MotifTheme.Typography.callout.monospaced())
                    .lineLimit(1)
            }
        }
        .frame(height: qcContentHeight)
        .accessibilityLabel(glyphs.isEmpty ? cmd.label : "\(glyphs) \(cmd.label)")
    }
}

private struct QuickCommandButtonStyle: ButtonStyle {
    /// Called when the press state flips (true = finger down, false = up /
    /// cancelled). Drives hold-to-repeat without firing on press-down (which
    /// would break scroll-over-button), since the Button's own action still
    /// owns the single-tap fire.
    var onPressChange: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, MotifTheme.Spacing.lg)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    configuration.isPressed ? MotifTheme.Fill.pressed : MotifTheme.Fill.subtle
                )
            )
            .foregroundStyle(MotifTheme.textPrimary)
            .contentShape(Capsule())
            .onChange(of: configuration.isPressed) { _, pressed in
                onPressChange?(pressed)
            }
    }
}

/// A quick-command capsule that single-fires on tap and — when `repeatEnabled`
/// — auto-repeats while held down (key-repeat style). Lives inside a horizontal
/// ScrollView, so repeat is driven by a `LongPressGesture` (which fails if the
/// finger moves to scroll) plus the button style's press-state callback to stop
/// on release; a stationary hold repeats, a swipe still scrolls.
private struct QuickCommandButton<Label: View>: View {
    let repeatEnabled: Bool
    let fire: () -> Void
    let label: Label

    @State private var repeatTask: Task<Void, Never>?
    @State private var didRepeat = false

    init(repeatEnabled: Bool, fire: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.repeatEnabled = repeatEnabled
        self.fire = fire
        self.label = label()
    }

    var body: some View {
        Button {
            // The trailing tap-up after a hold that already auto-repeated would
            // be a spurious extra fire — swallow it.
            if didRepeat { return }
            fire()
        } label: {
            label
        }
        .buttonStyle(QuickCommandButtonStyle(onPressChange: { pressed in
            if pressed {
                didRepeat = false   // new press
            } else {
                stopRepeat()
            }
        }))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                guard repeatEnabled else { return }
                didRepeat = true
                startRepeat()
            }
        )
        .onDisappear { stopRepeat() }
    }

    private func startRepeat() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            // First auto-fire lands at the hold threshold, then a steady ~11/s.
            while !Task.isCancelled {
                fire()
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// Sticky Ctrl / Alt / Shift button. Inactive blends with the regular QuickCommand
/// strip; armed shows an accent stroke; locked is an accent fill with a
/// small dot below to disambiguate "armed once" from "latched on".
private struct StickyModifierButton: View {
    let label: String
    let symbol: String
    let state: StickyState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: symbol)
                .font(MotifTheme.Typography.callout)
                .frame(height: qcContentHeight)
                .padding(.horizontal, MotifTheme.Spacing.lg)
                .padding(.vertical, 9)
            .background(background)
            .foregroundStyle(foreground)
            .overlay(alignment: .bottom) {
                if state == .locked {
                    Circle()
                        .fill(MotifTheme.accent)
                        .frame(width: 3, height: 3)
                        .offset(y: 3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .inactive:
            Capsule().fill(MotifTheme.Fill.subtle)
        case .armed:
            Capsule()
                .fill(MotifTheme.accent.opacity(0.18))
                .overlay(Capsule().strokeBorder(MotifTheme.accent, lineWidth: 1.2))
        case .locked:
            Capsule().fill(MotifTheme.accent)
        }
    }

    private var foreground: Color {
        state == .locked ? MotifTheme.textOnAccent : MotifTheme.textPrimary
    }

    private var accessibilityValue: String {
        switch state {
        case .inactive: return "off"
        case .armed:    return "armed"
        case .locked:   return "locked"
        }
    }
}
