import AppKit
import SwiftUI

/// Floating indicator at the bottom-center of the screen: a row of dots that
/// bounce with your voice while listening, and ripple left-to-right while
/// transcribing. Non-activating and click-through, so it never steals focus
/// from the app you're dictating into.
@MainActor
final class RecordingOverlay: ObservableObject {
    enum Mode {
        case listening
        case processing
    }

    @Published var mode: Mode = .listening
    @Published var level: Float = 0

    private var panel: NSPanel?
    private static let size = CGSize(width: 132, height: 52)

    /// Called from AudioRecorder with each buffer's RMS level (0…1).
    func setLevel(_ newLevel: Float) {
        // Smooth so bars breathe instead of jittering.
        level = level * 0.6 + newLevel * 0.4
    }

    func show(_ mode: Mode) {
        self.mode = mode
        let panel = self.panel ?? makePanel()
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        level = 0
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(overlay: self))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.minY + 16
        ))
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var overlay: RecordingOverlay

    private let dotCount = 5
    private let dotSize: CGFloat = 9
    private let dotSpacing: CGFloat = 11
    private let maxHop: CGFloat = 18

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: dotSpacing) {
                ForEach(0..<dotCount, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: dotOffset(index: index, time: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 11)
        }
        .background(
            Capsule()
                .fill(.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        )
        .padding(4)
    }

    /// Listening: staggered hops whose height follows the live mic level —
    /// the louder you speak, the higher the dots jump. Processing: a single
    /// gentle bump travelling left → right, like a loading ripple.
    private func dotOffset(index: Int, time: TimeInterval) -> CGFloat {
        switch overlay.mode {
        case .listening:
            let phase = Double(index) * 0.45
            let hop = abs(sin(time * 5.5 + phase)) // 0…1 bounce
            let height = 2 + maxHop * CGFloat(min(overlay.level, 1))
            return -height * CGFloat(hop)
        case .processing:
            // Ripple position sweeps across the row (with a little run-off
            // on both ends so the wave enters and exits smoothly).
            let sweep = (time * 1.4).truncatingRemainder(dividingBy: 1)
            let position = sweep * Double(dotCount + 2) - 1
            let lift = max(0, 1 - abs(Double(index) - position) / 1.3)
            return -9 * CGFloat(lift)
        }
    }
}
