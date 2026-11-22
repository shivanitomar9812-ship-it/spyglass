// Spyglass: The floating panel window, menu bar item and app delegate.
import AppKit
import Combine
import SwiftUI

// MARK: - Window

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: Panel!
    let store = Store()
    var statusItem: NSStatusItem!
    var quitReason = "unknown"
    var previousApp: NSRunningApplication?
    var fit: (() -> Void)?
    var changes: AnyCancellable?
    var sigterm: DispatchSourceSignal?

    func log(_ msg: String) {
        let url = Store.home.appendingPathComponent("spyglass.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    func showPanel() { panel.orderFrontRegardless(); UserDefaults.standard.set(false, forKey: "panelHidden") }
    func hidePanel() { TipCenter.shared.hide(); panel.orderOut(nil); UserDefaults.standard.set(true, forKey: "panelHidden") }
    @objc func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }
    @objc func showWelcome() { store.reopenWelcome(); showPanel() }
    @objc func quit() { quitReason = "quit from menu bar"; NSApp.terminate(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: panel.isVisible ? "Hide Spyglass" : "Show Spyglass", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Show welcome", action: #selector(showWelcome), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Spyglass", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
    }

    func applicationWillTerminate(_ n: Notification) { log("exit: \(quitReason)") }

    lazy var hotkeys = Hotkeys { [weak self] action in
        guard let self else { return }
        switch action {
        case .toggle: self.togglePanel()
        case .jump:
            if let s = self.store.longestWaiting { self.store.jump(s) }
            else { self.showPanel() }   // nothing waiting: just show the panel
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if store.hotkeys { hotkeys.enable() }
        store.onHotkeysChanged = { [weak self] on in if on { self?.hotkeys.enable() } else { self?.hotkeys.disable() } }
        log("start pid \(ProcessInfo.processInfo.processIdentifier)")
        ProcessInfo.processInfo.disableAutomaticTermination("Spyglass panel stays open")
        ProcessInfo.processInfo.disableSuddenTermination()
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.quitReason = "SIGTERM"; NSApp.terminate(nil) }
        term.resume()
        sigterm = term

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Spyglass")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        store.onHidePanel = { [weak self] in self?.hidePanel() }
        store.onLog = { [weak self] m in self?.log(m) }
        store.onNeedsYou = { [weak self] s in
            guard let self, !self.panel.isVisible else { return }
            self.log("shown: \(s.displayTitle) needs you")
            self.showPanel()
        }
        // Typing a name needs keyboard focus; hand it back to the previous app afterwards.
        store.onEditFocus = { [weak self] on in
            guard let self else { return }
            if on {
                self.previousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
            } else {
                if let p = self.previousApp, p != NSRunningApplication.current { p.activate() }
                self.previousApp = nil
            }
        }

        let host = NSHostingView(rootView: SpyglassView(store: store))
        // Host sits in a plain container with autoresizing (no constraints), so it reports its
        // size but cannot resize the window; the timer below resizes it, anchored at the top.
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        host.frame = container.bounds
        container.addSubview(host)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                      backing: .buffered, defer: false)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if !panel.setFrameUsingName("SpyglassPanel"), let scr = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: scr.maxX - 400, y: scr.maxY - 20))
        }
        panel.setFrameAutosaveName("SpyglassPanel")
        if !UserDefaults.standard.bool(forKey: "panelHidden") { panel.orderFrontRegardless() }

        // Keep the window sized to its content, anchored at the top edge: when the content changes (and on a slow
        // fallback tick for size changes that come from inside a view), not four times a second.
        fit = { [weak self] in
            guard let self else { return }
            let waiting = self.store.sessions.filter { $0.state == "waiting" }.count
            let title = waiting > 0 ? " \(waiting)" : ""
            if self.statusItem.button?.title != title { self.statusItem.button?.title = title }
            let size = host.fittingSize
            guard size.height > 1 else { return }
            var f = self.panel.frame
            if abs(f.height - size.height) > 0.5 {
                f.origin.y += f.height - size.height
                f.size = size
                self.panel.setFrame(f, display: true)
            }
        }
        changes = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit?() }   // after the change has been applied
        }
        let fallback = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.fit?() }
        fallback.tolerance = 0.5
    }
}
