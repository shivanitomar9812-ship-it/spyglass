// Spyglass: Test modes for tests/run.sh: --selftest prints row state, --snapshot renders the panel.
import AppKit
import SwiftUI

// MARK: - Test modes (tests/run.sh): no window, no sounds. Use with SPYGLASS_HOME=<fixtures> SPYGLASS_NO_REGISTRY=1.

/// --selftest: print each row's computed state as JSON lines, then exit.
/// --snapshot <out.png>: render the panel from the same state to a PNG, then exit.
@MainActor func runTestMode() -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--selftest") || args.contains("--snapshot") || args.contains("--away-selftest") else { return false }
    Store.snapshotMode = true
    TokenCounter.forceSynchronous = true
    let store = Store()
    store.muted = true
    store.showEnded = true
    store.compact = false   // tests choose with --state {"compact":"true"}; never the user's saved preference
    store.collapsed = false; store.muted = true   // likewise: snapshots never depend on the user's panel settings
    store.showWelcome = false                     // --state {"welcome":"true"} shows it
    store.soundDone = true; store.soundNeeds = true; store.autoShow = true
    if let i = args.firstIndex(of: "--state"), i + 1 < args.count, let data = args[i + 1].data(using: .utf8),
       let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        // UI state that only clicks create, e.g. {"confirming:<id>":"sonnet","editing":"<id>"}
        for (k, v) in o {
            if k.hasPrefix("confirming:") { store.confirming[String(k.dropFirst(11))] = v }
            if k == "editing" { store.editing = v }
            if k == "compact" { store.compact = v == "true" }
            if k == "welcome" { store.showWelcome = v == "true" }
            if k == "collapsed" { store.collapsed = v == "true" }
            if k == "query" { store.query = v }
            if k == "away" { store.away = v == "true" }
            if k.hasPrefix("peekOpen:") { store.peekOpen.insert(String(k.dropFirst(9))) }
            if ["soundDone", "soundNeeds", "autoShow"].contains(k) {
                switch k { case "soundDone": store.soundDone = v == "true"; case "soundNeeds": store.soundNeeds = v == "true"; default: store.autoShow = v == "true" }
            }
        }
    }
    if args.contains("--away-selftest") {   // run the phone bridge against SPYGLASS_TELEGRAM_API for N seconds, reloading as fixtures change
        let secs = args.firstIndex(of: "--away-selftest").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 3
        store.awayBridge.reloadConfig()
        if FileManager.default.fileExists(atPath: Store.awayFile) { store.away = true }
        let end = Date().addingTimeInterval(secs)
        while Date() < end { store.reload(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        return true
    }
    var wakes: [String] = []
    store.onNeedsYou = { wakes.append($0.id) }
    store.reload()
    if let i = args.firstIndex(of: "--reply"), i + 1 < args.count {   // e.g. --reply s1:allow
        let parts = args[i + 1].split(separator: ":").map(String.init)
        if parts.count == 2, let s = store.sessions.first(where: { $0.id == parts[0] }) { store.reply(s, approve: parts[1] == "allow") }
    }
    if let i = args.firstIndex(of: "--say"), i + 1 < args.count {   // e.g. --say s1:yes  (send.sh logs it via SPYGLASS_SEND_LOG)
        let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let s = store.sessions.first(where: { $0.id == parts[0] }) {
            store.sendReply(s, parts[1])
            Thread.sleep(forTimeInterval: 1.5)   // send.sh runs in the background
        }
    }
    if args.contains("--twice") {   // tests change fixtures meanwhile
        Thread.sleep(forTimeInterval: 1.5)
        store.reload()
    }
    if args.contains("--selftest") {
        if let d = try? JSONSerialization.data(withJSONObject: ["wakes": wakes]) { print(String(data: d, encoding: .utf8)!) }
        if let d = try? JSONSerialization.data(withJSONObject: ["peek": store.peek.map(\.id)]) { print(String(data: d, encoding: .utf8)!) }
        if let d = try? JSONSerialization.data(withJSONObject: ["peekOpen": Array(store.peekOpen).sorted()]) { print(String(data: d, encoding: .utf8)!) }
        if let d = try? JSONSerialization.data(withJSONObject: ["shown": store.shown.map(\.id), "shownEnded": store.shownEnded.map(\.id),
                                                                "hiddenWaiting": store.hiddenWaiting] as [String: Any], options: [.sortedKeys]) {
            print(String(data: d, encoding: .utf8)!)
        }
        print("{\"longestWaiting\":\"\(store.longestWaiting?.id ?? "")\"}")
        print("{\"waitedToday\":\(Int(store.waitedToday))}")
        for s in store.sessions {
            var row: [String: Any] = ["id": s.id, "name": s.displayTitle, "state": s.state, "contextFull": s.contextFull,
                                      "canRename": store.canRename(s)]
            row["model"] = s.model; row["ctx"] = s.ctx; row["tabName"] = s.tabName
            row["permission"] = s.permission?.detail; row["risky"] = s.permission?.riskReason
            row["asked"] = s.asked?.text
            row["remote"] = s.remote; row["canRemote"] = store.canToggleRemote(s); row["remoteHelp"] = store.remoteHelp(s)
            row["prompt"] = s.prompt; row["hooksQuiet"] = s.hooksQuiet != nil
            row["lastLine"] = s.lastLine; row["oldHooks"] = store.oldHooks(s); row["hooksMissing"] = s.hooksMissing ?? false
            if s.asked != nil { row["canReply"] = store.canReply(s); row["yesNo"] = Store.isYesNo(s.asked!.text) }
            row["canAnswer"] = s.permission != nil ? store.canAnswerPermission(s) : nil
            row["question"] = s.question.map { "\($0.text)|\(($0.options ?? []).joined(separator: ","))" }
            row["tokens"] = s.tokens?.used; row["usage"] = store.usageLabel(s)
            row["hover"] = store.rowHelp(s); row["ctxHover"] = store.contextHelp(s)
            let c = store.caps(s); row["caps"] = "\(c.app)|\(c.typeText ? "type" : "-")|\(c.pressKeys ? "keys" : "-")"
            if let d = try? JSONSerialization.data(withJSONObject: row.compactMapValues { $0 }, options: [.sortedKeys]) {
                print(String(data: d, encoding: .utf8)!)
            }
        }
        let layout = store.compactLayout()
        let lay: [String: Any] = ["full": layout.full.map(\.id), "groups": layout.groups.map { ["name": $0.name, "rows": $0.rows.map(\.id)] }]
        if let d = try? JSONSerialization.data(withJSONObject: ["compact": lay], options: [.sortedKeys]) { print(String(data: d, encoding: .utf8)!) }
        let lim = store.limits.map { ["key": $0.key, "left": $0.left] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: ["limits": lim], options: [.sortedKeys]) { print(String(data: d, encoding: .utf8)!) }
        for (name, t) in [("short", "Jump to iTerm2"),
                          ("long", String(repeating: "Last prompt: a very long prompt that should wrap onto several lines ", count: 3)), ("usage", "5h: 21% used, 79% left, renews 19:00\nWeek: 8% used, 92% left, renews Fri 22:30"),
                          ("row", store.sessions.first.map { store.rowHelp($0) } ?? "x")] {
            let z = TipCenter.measure(t)
            print("{\"tip\":\"\(name)\",\"w\":\(Int(z.width)),\"h\":\(Int(z.height))}")
        }
        let st = store.setupState()
        print("{\"setup\":{\"stats\":\(st.stats),\"editors\":\"\(st.editors.joined(separator: ","))\",\"extension\":\(st.editorExtension)}}")
        print("{\"overLimit\":\(store.overLimit),\"spend\":\(store.spendLimit?.usd.map { String($0) } ?? "null")}")
        for e in store.ended { print("{\"ended\":\"\(e.id)\",\"name\":\"\(e.displayTitle)\"}") }
        // A hover card whose text changes under the pointer (the header lock) shows the new text.
        let tid = UUID()
        TipCenter.shared.hover(tid, "before click", true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        TipCenter.shared.update(tid, "after click")
        print("{\"tipAfterUpdate\":\"\(TipCenter.shared.lastText ?? "")\"}")
        TipCenter.shared.hide()
    }
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        let renderer = ImageRenderer(content: SpyglassView(store: store).environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        } else { FileHandle.standardError.write("snapshot failed\n".data(using: .utf8)!); exit(1) }
    }
    return true
}
