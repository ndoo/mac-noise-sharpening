import AppKit
import SwiftUI

private struct HUDView: View {
    let level: Float
    let muted: Bool

    private var symbol: String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        return level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        let filled = muted ? 0 : Int((level * 16).rounded())
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(width: 30)
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < filled ? Color.primary.opacity(0.95) : Color.primary.opacity(0.25))
                        .frame(width: 8, height: 10)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(width: 300, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// Stand-in for the system volume pop-up, which is not available to apps.
final class VolumeHUD {
    private let panel: NSPanel
    private let host = NSHostingView(rootView: HUDView(level: 0, muted: false))
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
    }

    func show(level: Float, muted: Bool) {
        host.rootView = HUDView(level: level, muted: muted)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.minY + 100))
        }
        hideTimer?.invalidate()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
    }
}
