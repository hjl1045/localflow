import AppKit
import SwiftUI

/// Where the listening pill sits on screen. Left/right-center render vertically
/// (bars stacked, hugging the edge); the rest render horizontally.
enum OverlayPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case leftCenter, rightCenter
    case bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top center"
        case .topRight: "Top right"
        case .leftCenter: "Left center"
        case .rightCenter: "Right center"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        }
    }

    var isVertical: Bool { self == .leftCenter || self == .rightCenter }
}

/// Floating pill at a chosen screen edge: a flowing waveform that reacts to your
/// voice while listening, and idles gently while transcribing. Non-activating
/// and click-through, so it never steals focus from the app you're dictating
/// into. Its position is user-configurable (see `OverlayPosition`).
@MainActor
final class RecordingOverlay: ObservableObject {
    enum Mode {
        case listening
        case processing
    }

    @Published var mode: Mode = .listening
    @Published var level: Float = 0
    /// Set from AppState; drives both where the panel sits and whether the
    /// waveform lays out vertically.
    @Published var position: OverlayPosition = .bottomCenter

    private var panel: NSPanel?
    /// Bumped by every show/preview/hide so a preview's delayed auto-hide can
    /// tell it's been superseded by a real session (and not hide it).
    private var generation = 0

    // 2/3 of the original 180 pt. Short side stays 40; orientation swaps them.
    private static let longSide: CGFloat = 120
    private static let shortSide: CGFloat = 40
    private static let margin: CGFloat = 16

    private var overlaySize: CGSize {
        position.isVertical
            ? CGSize(width: Self.shortSide, height: Self.longSide)
            : CGSize(width: Self.longSide, height: Self.shortSide)
    }

    /// Called from AudioRecorder with each buffer's RMS level (0…1).
    func setLevel(_ newLevel: Float) {
        // Smooth so bars breathe instead of jittering.
        level = level * 0.6 + newLevel * 0.4
    }

    func show(_ mode: Mode) {
        generation += 1
        present(mode)
    }

    /// Briefly flash the pill at the current position so the user can see where
    /// it lands when they change the setting — it otherwise only appears while
    /// dictating. Auto-hides after 1.5 s unless a real session takes over.
    func preview() {
        generation += 1
        let token = generation
        present(.listening)
        level = 0.5 // liven the bars for the preview
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == token else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        level = 0
    }

    private func present(_ mode: Mode) {
        self.mode = mode
        let panel = self.panel ?? makePanel()
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: overlaySize),
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

    /// Size + place the panel for the current position (also resizes it when the
    /// orientation changed since last shown).
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = overlaySize
        let m = Self.margin

        let x: CGFloat
        switch position {
        case .topLeft, .leftCenter, .bottomLeft:
            x = frame.minX + m
        case .topCenter, .bottomCenter:
            x = frame.midX - size.width / 2
        case .topRight, .rightCenter, .bottomRight:
            x = frame.maxX - size.width - m
        }

        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight:
            y = frame.maxY - size.height - m
        case .leftCenter, .rightCenter:
            y = frame.midY - size.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = frame.minY + m
        }

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var overlay: RecordingOverlay

    private let barCount = 16
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minBar: CGFloat = 4
    private let maxBar: CGFloat = 24

    /// Soft light-yellow bars.
    private let barColor = Color(red: 1.0, green: 0.93, blue: 0.5)

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            bars(time: time)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            Capsule()
                .fill(.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        )
        .padding(4)
    }

    /// Horizontal (bars vary in height) or vertical (bars vary in width) so the
    /// same waveform reads correctly on a top/bottom edge or a left/right edge.
    @ViewBuilder
    private func bars(time: TimeInterval) -> some View {
        if overlay.position.isVertical {
            VStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor.opacity(0.95))
                        .frame(width: barExtent(index: index, time: time), height: barWidth)
                }
            }
        } else {
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor.opacity(0.95))
                        .frame(width: barWidth, height: barExtent(index: index, time: time))
                }
            }
        }
    }

    /// How far a bar extends (height when horizontal, width when vertical). A
    /// travelling sine wave gives the "flowing" motion; while listening its
    /// amplitude is driven by the live mic level, while processing it idles.
    private func barExtent(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.55
        let wave = (sin(time * 7 + phase) + 1) / 2 // 0…1, flowing along the pill

        let amplitude: CGFloat
        switch overlay.mode {
        case .listening:
            amplitude = 0.15 + CGFloat(min(overlay.level, 1)) * 0.85
        case .processing:
            amplitude = 0.3
        }
        return minBar + (maxBar - minBar) * amplitude * CGFloat(wave)
    }
}
