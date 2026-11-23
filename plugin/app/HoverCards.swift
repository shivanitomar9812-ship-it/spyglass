// Spyglass: Hover cards that work while Spyglass isn't the active app (macOS hides .help tooltips then).
import AppKit
import SwiftUI

// MARK: - Hover cards

/// macOS only shows standard tooltips (.help) for the active app, and Spyglass's panel never activates
/// (so clicking it doesn't steal focus). Spyglass draws its own hover card in a small floating window instead.
final class TipCenter {
    static let shared = TipCenter()
    private var window: NSPanel?
    private var host: NSHostingController<TipView>?
    private var pending: DispatchWorkItem?
    /// Hovered areas, outermost first: a row, then e.g. its context % inside it. The innermost one shows.
    private var stack: [(id: UUID, text: String)] = []
    private var shown: UUID?
    private(set) var lastText: String?   // for tests

    func hover(_ id: UUID, _ text: String, _ inside: Bool) {
        stack.removeAll { $0.id == id }
        if inside, !text.isEmpty { stack.append((id, text)) }
        guard let top = stack.last else { hide(); return }
        guard top.id != shown else { return }
        pending?.cancel()
        let wasShowing = window?.isVisible == true
        let work = DispatchWorkItem { [weak self] in self?.shown = top.id; self?.show(top.text) }
        pending = work
        // Moving between areas while a card is up switches at once; a fresh hover waits a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasShowing ? 0.05 : 0.45), execute: work)
    }

    /// The hovered area's text changed under the pointer (e.g. the lock was clicked): refresh the card in place.
    func update(_ id: UUID, _ text: String) {
        guard let i = stack.firstIndex(where: { $0.id == id }), !text.isEmpty else { return }
        stack[i].text = text
        if shown == id, window?.isVisible == true { show(text) }
    }

    func hide() {
        pending?.cancel(); pending = nil; stack.removeAll(); shown = nil
        window?.orderOut(nil)
    }

    private func show(_ text: String) {
        lastText = text
        let view = TipView(text: text)
        if window == nil {
            let w = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let h = NSHostingController(rootView: view)
            h.sizingOptions = []   // the window is sized below, from measure()
            w.contentViewController = h
            window = w; host = h
        } else {
            host?.rootView = view
        }
        guard let w = window else { return }
        let size = TipCenter.measure(text)
        // Below-right of the pointer, kept on screen.
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: m.x + 14, y: m.y - 18 - size.height)
        if origin.x + size.width > screen.maxX { origin.x = m.x - 14 - size.width }
        if origin.y < screen.minY { origin.y = m.y + 18 }
        origin.x = max(origin.x, screen.minX + 4)
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.orderFrontRegardless()
    }
}

extension TipCenter {
    static let maxWidth: CGFloat = 360
    /// The card's size at its real width (measuring with unknown width wraps word by word: a very tall window).
    static func measure(_ text: String) -> CGSize {
        let h = NSHostingController(rootView: TipView(text: text, fill: false))
        // Natural width first (one line per text line); wrap only past maxWidth.
        var fit = h.sizeThatFits(in: CGSize(width: 10_000, height: 2_000))
        if fit.width > maxWidth + 20 { fit = h.sizeThatFits(in: CGSize(width: maxWidth + 20, height: 2_000)) }
        return CGSize(width: ceil(fit.width), height: ceil(fit.height))
    }
}

struct TipView: View {
    let text: String
    var fill = true   // false when measuring: the card's own size
    var body: some View {
        if fill { card.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) } else { card }
    }
    var card: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(.white.opacity(0.92))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14), lineWidth: 1))
            // (fill: if the window is ever larger than the card, the card stays top-left, next to the pointer)
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onHover { TipCenter.shared.hover(id, text, $0) }
            .onChange(of: text) { TipCenter.shared.update(id, $0) }
            .onDisappear { TipCenter.shared.hover(id, "", false) }
    }
}

extension View {
    /// Hover card that works while Spyglass isn't the active app (replaces .help).
    func tip(_ text: String) -> some View { modifier(TipModifier(text: text)) }
}
