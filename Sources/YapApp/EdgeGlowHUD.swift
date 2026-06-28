import AppKit
import SwiftUI

// The dictation indicator: a light, animated glow ("aura") hugging the bottom edge of
// the screen the user is working on. No transcript, no controls — a click-through
// ambient cue that says "listening". This is the only on-screen recording indicator.

/// The aura's palette (cyan → blue → violet).
enum AuraColors {
    static let electricCyan = Color(red: 0.420, green: 0.940, blue: 1)
    static let electricBlueBright = Color(red: 0.250, green: 0.570, blue: 1)
    static let ultraviolet = Color(red: 0.500, green: 0.250, blue: 1)
}

@MainActor
final class EdgeGlowModel: ObservableObject {
    // @Published so flipping it mounts/unmounts the render loop (see EdgeGlowView).
    @Published var active = false
    // When false, no real mic levels feed the glow (the Parakeet daemon owns the mic in a
    // separate process), so the render loop breathes a synthetic level instead of sitting at
    // a dead baseline. Cloud dictation leaves this true and stays voice-reactive.
    var voiceReactive = true
    // `level` is the raw mic target; `displayedLevel` is the render-smoothed value we
    // actually draw. Plain vars (not @Published): the TimelineView drives the redraws,
    // and the per-frame easing reads/writes these without retriggering SwiftUI.
    var level: Double = 0
    var displayedLevel: Double = 0
    var lastTick: TimeInterval = 0
}

enum EdgeGlowLayout {
    /// A low, soft band hugging the bottom edge — tall enough to fade out cleanly,
    /// short enough to stay out of the way.
    static let panelHeight: CGFloat = 100
}

@MainActor
final class EdgeGlowHUD {
    private var panel: NSPanel?
    private let model = EdgeGlowModel()

    func show(voiceReactive: Bool = true) {
        model.voiceReactive = voiceReactive
        // Idempotent: the dictation state (and thus this call) is re-emitted on every
        // partial transcript (~10×/s), but the panel is already up — bail out so we
        // don't re-order it to the front against the window server on every update.
        if model.active { return }
        if panel == nil { panel = makePanel() }
        // Capture the active screen only when the glow first appears, so it stays put
        // for the session even if the cursor wanders to the other monitor.
        if !(panel?.isVisible ?? false) { positionOnActiveScreen() }
        model.active = true
        panel?.orderFrontRegardless()
    }

    /// Flip between voice-reactive (real mic levels) and self-breathing (synthetic). Used by
    /// the Parakeet path: it shows breathing immediately, then switches to true reactivity once
    /// its parallel level meter starts delivering real levels.
    func setVoiceReactive(_ on: Bool) { model.voiceReactive = on }

    func updateLevel(_ level: Double) {
        // Just record the raw target; the smoothing happens per render frame (dt-aware)
        // so it stays fluid regardless of how coarsely the mic reports levels.
        model.level = level
    }

    func hide() {
        model.active = false
        model.level = 0
        // Reset the render-smoothed state too, so the next session's glow starts from
        // the baseline instead of easing down from the previous session's brightness.
        model.displayedLevel = 0
        model.lastTick = 0
        panel?.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        guard let panel else { return }
        let frame = Self.activeScreen().frame
        panel.setFrame(
            NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: EdgeGlowLayout.panelHeight),
            display: true
        )
    }

    /// The screen the user is working on: the one containing the mouse cursor, falling
    /// back to the key-window screen. Robust across multiple monitors.
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: EdgeGlowLayout.panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // purely decorative — never steal clicks
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: EdgeGlowView(model: model))
        host.frame = NSRect(origin: .zero, size: CGSize(width: 100, height: EdgeGlowLayout.panelHeight))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

struct EdgeGlowView: View {
    @ObservedObject var model: EdgeGlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // Only mount the per-frame render loop while actually listening. When idle the
            // glow is hidden, so rendering nothing here stops TimelineView(.animation)
            // entirely — instead of burning CPU drawing invisible frames 24/7.
            if model.active {
                if reduceMotion {
                    glow(width: geo.size.width, height: geo.size.height, time: 0)
                } else {
                    // Cap at ~30fps: a slow, heavily-blurred ambient glow looks identical
                    // to 120fps ProMotion but draws ~4x less, which matters for battery
                    // during a long dictation. The easing in `glow` is dt-aware, so the
                    // lower cadence stays smooth and voice-reactive.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        glow(width: geo.size.width, height: geo.size.height,
                             time: context.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func glow(width: CGFloat, height: CGFloat, time: TimeInterval) -> some View {
        // Render-rate envelope follower (dt-aware → smooth at any frame rate): snap up
        // fast with the voice, ease down slowly. This is what kills the jitter while
        // staying reactive — the raw mic level is too coarse to draw directly.
        let dt = max(0, min(0.1, time - model.lastTick))
        model.lastTick = time
        // No real mic levels yet (Parakeet's daemon owns the mic) → hold a steady baseline
        // rather than self-animating. The aura stays static; the ONLY thing that moves is the
        // voice once real mic levels start feeding in (`voiceReactive`).
        if !model.voiceReactive {
            model.level = 0.5
        }
        let tau = model.level > model.displayedLevel ? 0.045 : 0.16
        model.displayedLevel += (model.level - model.displayedLevel) * (1 - exp(-dt / tau))
        let level = CGFloat(min(max(model.displayedLevel, 0), 1))
        // Low baseline + wide swing so the voice clearly drives the brightness.
        let intensity = 0.22 + 0.78 * pow(level, 0.55)

        return ZStack {
            // Three screen-wide, heavily-blurred colour fields sit at FIXED positions and
            // overlap completely, melting into ONE continuous, motionless wash. Nothing here
            // drifts or bobs — only the shared `intensity` (driven by the mic) changes.
            flowField(AuraColors.electricCyan,       center: 0.28, width: width, height: height, intensity: intensity)
            flowField(AuraColors.electricBlueBright, center: 0.52, width: width, height: height, intensity: intensity)
            flowField(AuraColors.ultraviolet,        center: 0.74, width: width, height: height, intensity: intensity)
        }
        .compositingGroup()
        .frame(width: width, height: height, alignment: .bottom)
        .mask(
            // The glow always melts to nothing toward the top — never a hard cut.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.62),
                    .init(color: .black, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .mask(
            // ...and tapers down toward both screen edges, so neither left nor right is a
            // straight cut — a soft mound rather than a flat bar.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    private func flowField(_ color: Color, center: CGFloat,
                           width: CGFloat, height: CGFloat, intensity: CGFloat) -> some View {
        // Fixed position — no time-based drift or bob. The field is anchored to the bottom
        // edge at a fixed horizontal center; the aura is static apart from voice intensity.
        let x = width * center
        let y = height
        return Ellipse()
            .fill(RadialGradient(colors: [color.opacity(0.50 * intensity), .clear],
                                 center: .center, startRadius: 0, endRadius: width * 0.40))
            .frame(width: width * 1.1, height: height * 1.4)
            .position(x: x, y: y)
            .blur(radius: 40)
            .blendMode(.screen)
    }
}
