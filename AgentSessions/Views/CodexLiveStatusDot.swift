import SwiftUI
import AppKit

struct CodexLiveStatusDot: View {
    let state: CodexLiveState
    var color: Color
    var size: CGFloat = 7
    var lastSeenAt: Date? = nil
    var idleReason: HUDIdleReason? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isAppActive: Bool = NSApp.isActive

    var body: some View {
        Group {
            if state == .activeWorking {
                staticActiveDot
            } else {
                animatedIdleDot
            }
        }
        .onAppear {
            isAppActive = NSApp.isActive
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isAppActive = false
        }
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var shouldPulse: Bool {
        state == .openIdle && !reduceMotion && isAppActive
    }

    private var idleBaseColor: Color {
        if idleReason == .errorOrStuck {
            return colorScheme == .dark ? Color(hex: "ff453a") : Color(hex: "d70015")
        }
        return colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }

    private var staticActiveDot: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .transaction { transaction in
                // Keep active (green) dots fully static even when parent rows animate.
                transaction.animation = nil
            }
    }

    // Pulse runs as a Core Animation layer animation on the render server.
    // SwiftUI repeatForever + .drawingGroup() re-rasterized an RBLayer every
    // frame on the main thread, and each re-rasterize blocked in RenderBox
    // wait_for_allocations until the previous frame was displayed: one idle dot
    // kept ~50% of the main thread waiting, so clicks queued behind it.
    private var animatedIdleDot: some View {
        PulsingDotLayerView(color: NSColor(idleBaseColor), pulsing: shouldPulse)
            .frame(width: size, height: size)
    }

    private var accessibilityLabel: String {
        switch state {
        case .activeWorking: return "Active session"
        case .openIdle: return idleReason?.label ?? "Open session"
        }
    }
}

/// Idle-dot pulse (scale 1→1.25, opacity 0.88→1, halo 0.22/3.2→0.65/4.8,
/// easeInOut 1.4s, autoreversing) driven entirely by Core Animation.
private struct PulsingDotLayerView: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> PulsingDotNSView { PulsingDotNSView() }

    func updateNSView(_ view: PulsingDotNSView, context: Context) {
        view.apply(color: color, pulsing: pulsing)
    }
}

private final class PulsingDotNSView: NSView {
    private let dot = CALayer()
    private var pulsing = false
    private static let pulseKey = "idlePulse"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        dot.opacity = 0.88
        dot.shadowOffset = .zero
        dot.shadowOpacity = 0
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = bounds
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimation()
    }

    func apply(color: NSColor, pulsing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        dot.shadowColor = color.cgColor
        CATransaction.commit()
        self.pulsing = pulsing
        syncAnimation()
    }

    private func syncAnimation() {
        guard pulsing, window != nil else {
            dot.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard dot.animation(forKey: Self.pulseKey) == nil else { return }
        func anim(_ keyPath: String, _ from: Any, _ to: Any) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from
            a.toValue = to
            return a
        }
        let group = CAAnimationGroup()
        group.animations = [
            anim("transform.scale", 1.0, 1.25),
            anim("opacity", 0.88, 1.0),
            anim("shadowOpacity", 0.22, 0.65),
            anim("shadowRadius", 3.2, 4.8),
        ]
        group.duration = 1.4
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(group, forKey: Self.pulseKey)
    }
}
