import AppKit
import SwiftUI

/// Floating pill at the bottom-center of the screen: a flowing waveform that
/// reacts to your voice while listening, and idles gently while transcribing.
/// Non-activating and click-through, so it never steals focus from the app
/// you're dictating into.
@MainActor
final class RecordingOverlay: ObservableObject {
    enum Mode {
        case listening
        case processing
    }

    @Published var mode: Mode = .listening
    @Published var level: Float = 0

    private var panel: NSPanel?
    private static let size = CGSize(width: 180, height: 40)

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

    private let barCount = 24
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 24

    /// Soft light-yellow bars (was white).
    private let barColor = Color(red: 1.0, green: 0.93, blue: 0.5)

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor.opacity(0.95))
                        .frame(width: barWidth, height: barHeight(index: index, time: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            Capsule()
                .fill(.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        )
        .padding(4)
    }

    /// A travelling sine wave gives the "flowing" motion; while listening its
    /// amplitude is driven by the live mic level, while processing it idles.
    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.55
        let wave = (sin(time * 7 + phase) + 1) / 2 // 0…1, flowing left→right

        let amplitude: CGFloat
        switch overlay.mode {
        case .listening:
            amplitude = 0.15 + CGFloat(min(overlay.level, 1)) * 0.85
        case .processing:
            amplitude = 0.3
        }
        return minBarHeight + (maxBarHeight - minBarHeight) * amplitude * CGFloat(wave)
    }
}
