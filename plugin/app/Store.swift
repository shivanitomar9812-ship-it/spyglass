// Spyglass: The panel's state: reads sessions from the registry, hooks, statusline and transcripts, and acts on them.
import AppKit
import SwiftUI

final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var muted: Bool = UserDefaults.standard.bool(forKey: "muted")
    @Published var collapsed: Bool = UserDefaults.standard.bool(forKey: "collapsed")
    /// Compact view: one line per session; on unless turned off.
    @Published var compact: Bool = UserDefaults.standard.object(forKey: "compact") as? Bool ?? true
    private var hidden: [String: Double] = [:]          // id -> updated-at when hidden
    private var lastState: [String: String] = [:]
    private let dir = Store.home.appendingPathComponent("sessions")
    static let home: URL = {
        if let h = ProcessInfo.processInfo.environment["SPYGLASS_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return URL(fileURLWithPath: Store.userHome).appendingPathComponent(".claude/spyglass")   // $HOME, like the scripts
    }()
    private var timer: Timer?
    private var watcher: Watcher?
    private var tickInterval: Double = 0

    /// Reloads when Spyglass's or Claude Code's session files change, plus a slow tick for clocks and process liveness:
    /// 2 s while a session is working, 10 s when all is quiet. (It used to re-read everything every second.)
    init() {
        reload()
        guard !Store.snapshotMode else { return }   // test modes reload explicitly
        watcher = Watcher(paths: [Store.home.path, Store.claudeDirURL.appendingPathComponent("sessions").path],
                          ignore: Store.ignoreChange) { [weak self] in self?.reload() }
        scheduleTick()
    }

    /// Changes that don't need a reload: what the panel writes itself, the editor's tab-name heartbeat, request plumbing.
    static func ignoreChange(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".tmp") || path.contains("/claims/") || path.contains("/terminals/") { return true }
        return ["tokens.json", "waits.json", "extra.json", "spyglass.log", "send-request.json", "send-response.json",
                "focus-request.json", "focus-response.json", "resume-request.json", "resume-response.json"].contains(name)
    }

    private func scheduleTick() {
        let want: Double = sessions.contains { $0.state == "working" } ? 2 : 10
        guard want != tickInterval else { return }
        tickInterval = want
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: want, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = want / 4   // let macOS batch the wake-up with others
    }

    @Published var olderIdle = 0
    /// Model switches in flight (or just failed), by session id.
    @Published var switching: [String: ModelSwitch] = [:]
    /// Model picked in the menu, waiting for the user's Switch / Cancel in the panel.
    @Published var confirming: [String: String] = [:]
    /// Session whose name is being edited in the panel, and renames in flight (or just failed).
    @Published var editing: String? = nil
    @Published var renaming: [String: Rename] = [:]
    var onEditFocus: ((Bool) -> Void)?
    @Published var replies: [String: Reply] = [:]
    /// Option picked for a question, in flight (or just failed): (label, question at, since, failed).
    @Published var answers: [String: Rename] = [:]
    /// Plan limits (freshest statusline that reported them); empty on API-key plans, where $ is the real bill.
    @Published var limits: [LimitWindow] = []
    let tokenCounter = TokenCounter(home: Store.home)
    private var lastTokenScan: Double = 0
    /// Recently ended sessions (ended/<id>.json), newest first, for the Resume list.
    @Published var ended: [Session] = []
    @Published var showEnded: Bool = UserDefaults.standard.bool(forKey: "showEnded")
    @Published var resuming: [String: (since: Double, failed: String?)] = [:]
    private var lastLive: [String: Session] = [:]
    private let endedDir = Store.home.appendingPathComponent("ended")
    static let endedWindow: Double = 24 * 3600
    static let endedMax = 10
    /// Context warning: sound once at ctxWarnAt%, re-armed only after dropping below ctxRearmAt% (e.g. after /compact).
    /// --snapshot: native controls (Menu) can't be rendered offscreen, so views draw a plain stand-in.
    static var snapshotMode = false
    static let ctxWarnAt = 85
    static let ctxRearmAt = 80
    private var ctxWarned: Set<String> = []
    private var ctxPrimed = false
    private var titles: [String: (title: String?, custom: Bool, checked: Double)] = [:]
    private var transcriptPaths: [String: URL] = [:]
    private let claudeDir: URL = Store.claudeDirURL
    static let claudeDirURL: URL = {
        if let d = ProcessInfo.processInfo.environment["SPYGLASS_CLAUDE_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()
    static let recentWindow: Double = 12 * 3600

    private func alive(_ pid: Int32?) -> Bool {
        guard let pid else { return true }
        return !(kill(pid, 0) != 0 && errno == ESRCH)
    }

    /// Claude Code's own registry of running sessions (~/.claude/sessions/<pid>.json).
    /// Lists every session, including ones started before Spyglass's hooks were installed.
    private func registry() -> [Session] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Session] = []
        for url in files where url.pathExtension == "json" {
            guard let o = cachedJSON(url),
                  let sid = o["sessionId"] as? String,
                  let pidN = o["pid"] as? NSNumber else { continue }
            let pid = pidN.int32Value
            guard alive(pid) else { continue }
            let cwd = o["cwd"] as? String
            let raw = o["status"] as? String ?? "idle"
            var s = Session(id: sid)
            s.source = "registry"
            s.cwd = cwd
            s.entrypoint = o["entrypoint"] as? String
            s.pid = pid
            s.started = (o["startedAt"] as? NSNumber).map { $0.doubleValue / 1000 }
            s.updated = (o["statusUpdatedAt"] as? NSNumber ?? o["updatedAt"] as? NSNumber).map { $0.doubleValue / 1000 }
            switch raw {
            case "busy": s.status = "working"; s.activity = "Working…"
            case "shell": s.status = "working"; s.activity = "Running a shell command"
            case "waiting", "needs_input", "blocked": s.status = "waiting"; s.activity = "Needs your input"
            default: s.status = "idle"; s.activity = "Idle"
            }
            s.turnStarted = s.updated
            if (o["nameSource"] as? String) != "derived", let n = o["name"] as? String, !n.isEmpty {
                s.title = n; s.titleSource = "custom"
            }
            if s.title == nil, let t = transcriptTitle(sid, cwd: cwd) { s.title = t.title; s.titleSource = t.custom ? "custom" : "ai" }
            out.append(s)
        }
        return out
    }

    /// Latest /rename or auto title from the session transcript (tail only; cached for 30s).
    private func transcriptTitle(_ sid: String, cwd: String?) -> (title: String, custom: Bool)? {
        let now = Date().timeIntervalSince1970
        if let c = titles[sid], now - c.checked < 30 { return c.title.map { ($0, c.custom) } }
        var title: String? = nil
        var isCustom = false
        if let url = transcriptURL(sid, cwd: cwd), let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
            if let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) {
                var custom: String? = nil, ai: String? = nil
                for line in text.split(separator: "\n") {
                    if line.contains("\"customTitle\""), let v = field(line, "customTitle") { custom = v }
                    else if line.contains("\"ai-title\""), let v = field(line, "aiTitle") { ai = v }
                }
                title = custom ?? ai
                isCustom = custom != nil
            }
        }
        titles[sid] = (title, isCustom, now)
        return title.map { ($0, isCustom) }
    }

    // MARK: Cursor / VS Code tab names

    /// Shell pid -> tab name, from terminals/<ext host pid>.json written by the editor core. Generic names don't count.
    private static let genericTabNames: Set<String> = ["zsh", "bash", "fish", "sh", "node", "claude", "login", "-zsh", "-bash"]
    private var lastTabPing: Double = 0
    private func tabNames(now: Double) -> (names: [Int32: String], fresh: Bool) {
        let fm = FileManager.default
        let dir = Store.home.appendingPathComponent("terminals")
        var names: [Int32: String] = [:]
        var fresh = false
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            guard let o = cachedJSON(url),
                  let ts = (o["ts"] as? NSNumber)?.doubleValue else { continue }
            if now - ts > 3600 { try? fm.removeItem(at: url); continue }   // window closed long ago
            guard now - ts <= 20 else { continue }
            fresh = true
            for row in o["rows"] as? [[String: Any]] ?? [] {
                guard let pid = (row["pid"] as? NSNumber)?.int32Value, let name = row["name"] as? String else { continue }
                // Claude Code prefixes its terminal title with a status symbol ("✳ ", spinner dots): not part of the name.
                let n = String(name.unicodeScalars.drop { !CharacterSet.alphanumerics.contains($0) && $0 != "(" && $0 != "[" })
                    .trimmingCharacters(in: .whitespaces)
                // Not a name you gave it: shell/process names, or a bare version ("2.1.330", Claude Code's process title).
                let isVersion = n.range(of: #"^v?\d+(\.\d+)+$"#, options: .regularExpression) != nil
                if !n.isEmpty, !isVersion, !Store.genericTabNames.contains(n.lowercased()) { names[pid] = n }
            }
        }
        return (names, fresh)
    }

    /// After a window reload the editor core loads lazily; a harmless ping makes it start publishing tab names.
    private func pingEditorForTabNames(now: Double) {
        guard now - lastTabPing > 15, switching.isEmpty, replies.isEmpty else { return }
        lastTabPing = now
        let url = Store.home.appendingPathComponent("send-request.json")
        let body = String(format: "{\"ts\":%.3f,\"shellPid\":0,\"text\":\"list:terminals\"}", now)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func parentPid(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    private func field(_ line: Substring, _ key: String) -> String? {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o[key] as? String
    }

    // MARK: Parse only what changed

    /// Parsed files, re-read only when their modification time or size changes (most files don't, most reloads).
    private var parsed: [String: (mtime: Date, size: Int, obj: Any)] = [:]
    private var seenPaths: Set<String> = []
    private func stamp(_ url: URL) -> (Date, Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let z = (a[.size] as? NSNumber)?.intValue else { return nil }
        return (m, z)
    }
    func cachedJSON(_ url: URL) -> [String: Any]? {
        seenPaths.insert(url.path)
        guard let (m, z) = stamp(url) else { return nil }
        if let c = parsed[url.path], c.mtime == m, c.size == z { return c.obj as? [String: Any] }
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        parsed[url.path] = (m, z, o)
        return o
    }
    func cachedSession(_ url: URL) -> Session? {
        seenPaths.insert(url.path)
        guard let (m, z) = stamp(url) else { return nil }
        if let c = parsed[url.path], c.mtime == m, c.size == z { return c.obj as? Session }
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Session.self, from: d) else { return nil }
        parsed[url.path] = (m, z, s)
        return s
    }
    /// Forget cache entries for files not seen in the last reload.
    private func pruneParsed() {
        if parsed.count > seenPaths.count { parsed = parsed.filter { seenPaths.contains($0.key) } }
        seenPaths.removeAll(keepingCapacity: true)
    }

    private var reportedQuiet: Set<String> = []
    static let quietAfter: Double = 300, quietStale: Double = 1800
    private var activity: [String: (modified: Double, prompt: String?, last: Double?)] = [:]
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let iso = ISO8601DateFormatter()
    /// From a transcript's tail: your latest message, and when the latest message (yours or Claude's) was written.
    /// Re-read only when the file changed.
    private func transcriptActivity(_ url: URL, modified: Double) -> (prompt: String?, last: Double?)? {
        if let c = activity[url.path], c.modified == modified { return (c.prompt, c.last) }
        var found: String? = nil, last: Double? = nil
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
            if let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n").reversed()
                where line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          (o["isMeta"] as? Bool) != true else { continue }
                    if last == nil, let ts = o["timestamp"] as? String,
                       let d = Store.isoFrac.date(from: ts) ?? Store.iso.date(from: ts) { last = d.timeIntervalSince1970 }
                    guard (o["type"] as? String) == "user" else { continue }
                    var t: String? = JSON.get(o, ".message.content") as? String
                    if t == nil, let parts = JSON.get(o, ".message.content") as? [[String: Any]] {
                        t = parts.first { ($0["type"] as? String) == "text" }?["text"] as? String   // tool results have no text part
                    }
                    guard let p = t?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
                          !p.hasPrefix("<"), !p.hasPrefix("[Request interrupted") else { continue }   // command echoes, interrupts
                    found = CLI.cut(CLI.oneLine(p), 120); break
                }
            }
        }
        activity[url.path] = (modified, found, last)
        return (found, last)
    }

    private var transcriptMisses: [String: Double] = [:]   // no transcript found: look again after a minute
    private func transcriptURL(_ sid: String, cwd: String?) -> URL? {
        if let u = transcriptPaths[sid] { return u }
        let now = Date().timeIntervalSince1970
        if let t = transcriptMisses[sid], now - t < 60 { return nil }
        let projects = claudeDir.appendingPathComponent("projects")
        var candidates: [URL] = []
        if let cwd {
            let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            candidates.append(projects.appendingPathComponent(slug).appendingPathComponent("\(sid).jsonl"))
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { transcriptPaths[sid] = c; return c }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let c = d.appendingPathComponent("\(sid).jsonl")
            if FileManager.default.fileExists(atPath: c.path) { transcriptPaths[sid] = c; return c }
        }
        transcriptMisses[sid] = now
        return nil
    }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970

        // Hook-recorded sessions: rich state (activity, progress, terminal location).
        var hooked: [String: Session] = [:]
        for url in files where url.pathExtension == "json" {
            guard let s = cachedSession(url) else { continue }
            if !alive(s.pid) { saveEnded(s); try? fm.removeItem(at: url); continue }   // ended without SessionEnd
            var h = s
            // Claude Code's one-minute idle reminder isn't a question (older hooks recorded it as "waiting").
            if h.state == "waiting", h.permission == nil, (h.activity ?? "").contains("waiting for your input") {
                h.status = "done"; h.activity = "Finished — ready for you"
            }
            hooked[s.id] = h
        }

        // Merge with Claude Code's registry so every running session appears.
        var merged = hooked
        let useRegistry = ProcessInfo.processInfo.environment["SPYGLASS_NO_REGISTRY"] != "1"   // off for demos/tests
        for r in useRegistry ? registry() : [] {
            if var h = merged[r.id] {
                h.pid = h.pid ?? r.pid
                h.entrypoint = h.entrypoint ?? r.entrypoint
                if h.title == nil { h.title = r.title }
                // Registry is fresher (e.g. hooks not loaded yet, or turn ended): trust its status.
                if (r.updated ?? 0) > (h.updated ?? 0) + 2, r.state != h.state, !(h.state == "done" && r.state == "idle") {
                    h.status = r.status; h.activity = r.activity; h.updated = r.updated
                }
                merged[r.id] = h
            } else {
                merged[r.id] = r
            }
        }

        // Names you gave the Cursor / VS Code terminal tabs (matched via claude's parent shell).
        let tabs = tabNames(now: now)
        if !tabs.fresh, merged.values.contains(where: { $0.term == "vscode" }) { pingEditorForTabNames(now: now) }
        for (id, var s) in merged {
            guard let pid = s.pid, let shell = Store.parentPid(pid) else { continue }
            s.tabName = tabs.names[shell]
            merged[id] = s
        }

        // Model / context / cost / plan limits, written by stats.sh from the statusline.
        var freshestLimits: (at: Double, windows: [LimitWindow])? = nil
        let statsDir = Store.home.appendingPathComponent("stats")
        for url in (try? fm.contentsOfDirectory(at: statsDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            let sid = url.deletingPathExtension().lastPathComponent
            guard let o = cachedJSON(url) else { continue }
            guard var s = merged[sid] else {
                if now - ((o["updated"] as? NSNumber)?.doubleValue ?? 0) > Store.recentWindow { try? fm.removeItem(at: url) }
                continue
            }
            s.model = o["model"] as? String
            s.ctx = (o["ctx"] as? NSNumber)?.intValue
            s.ctxTokens = (o["ctxTokens"] as? NSNumber)?.intValue
            s.ctxSize = (o["ctxSize"] as? NSNumber)?.intValue
            s.cost = (o["cost"] as? NSNumber)?.doubleValue
            merged[sid] = s
            let at = (o["updated"] as? NSNumber)?.doubleValue ?? 0
            if let l = o["limits"] as? [String: [String: Any]], at > (freshestLimits?.at ?? -1) {
                let w = l.compactMap { k, v -> LimitWindow? in
                    guard let p = (v["pct"] as? NSNumber)?.doubleValue else { return nil }
                    return LimitWindow(key: k, pct: p, resets: (v["resets"] as? NSNumber)?.doubleValue,
                                       usd: (v["usd"] as? NSNumber)?.doubleValue, limitUsd: (v["limitUsd"] as? NSNumber)?.doubleValue)
                }
                freshestLimits = (at, w.sorted { (LimitWindow.order.firstIndex(of: $0.key) ?? 99, $0.key) < (LimitWindow.order.firstIndex(of: $1.key) ?? 99, $1.key) })
            }
        }
        let newLimits = freshestLimits?.windows ?? []
        if newLimits != limits { limits = newLimits }
        trackExtraUsage(merged)

        // Tokens used, from transcripts (background, incremental).
        if now - lastTokenScan > 5 || tokenCounter.synchronous {
            lastTokenScan = now
            var paths: [String: URL] = [:]
            for s in merged.values { if let u = transcriptURL(s.id, cwd: s.cwd) { paths[s.id] = u } }
            tokenCounter.update(paths)
        }
        for (id, var s) in merged { s.tokens = tokenCounter.totals(id); merged[id] = s }

        // A finished turn that ended by asking you something waits on you. Hooks since 0.18 record it; the panel also
        // reads it from the transcript, so sessions running older hooks (or none) show it too.
        for (id, var s) in merged where s.permission == nil && s.question == nil && (s.state == "done" || s.state == "idle") {
            let r: (asked: Asked?, line: String?) = (s.asked == nil || s.lastLine == nil) ? lastReply(s) : (nil, nil)
            if s.lastLine == nil, let l = r.line { s.lastLine = l; merged[id] = s }
            if s.asked == nil, let q = r.asked {
                s.asked = q; s.status = "waiting"; s.activity = "Asked you: " + CLI.cut(q.text, 70)
                merged[id] = s
            }
        }

        // Hooks gone quiet: messages kept coming 5+ minutes after the last hook report (e.g. a session still running hooks
        // from a plugin since removed). Its record is stale: take the last prompt from the transcript; after 30 minutes (no
        // single step is that quiet) stop claiming it's "working" on whatever it was doing then.
        // Message timestamps, not the file's: Claude Code writes bookkeeping (away summaries…) long after a turn ends.
        for (id, var s) in merged where s.source != "registry" {
            guard let upd = s.updated, let url = transcriptURL(s.id, cwd: s.cwd),
                  let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  m.timeIntervalSince1970 - upd > Store.quietAfter,
                  let act = transcriptActivity(url, modified: m.timeIntervalSince1970), let last = act.last,
                  last - upd > Store.quietAfter else { continue }
            s.hooksQuiet = upd
            s.updated = last   // the conversation is what's active: never tuck a live session away as "older idle"
            if let p = act.prompt { s.prompt = p }
            if s.state == "working", last - upd > Store.quietStale {
                s.status = "idle"; s.activity = "No updates from its hooks: restart it (claude --resume)"
            }
            merged[id] = s
            if !reportedQuiet.contains(id) { reportedQuiet.insert(id); onLog?("hooks went quiet: \(s.displayTitle) (\(id))") }
        }

        // Sessions that vanished since the last reload (terminal closed, crash) are kept for Resume.
        for (id, s) in lastLive where merged[id] == nil { saveEnded(s) }
        lastLive = merged
        loadEnded(live: Set(merged.keys), now: now)

        // Self-check: a session started after this Spyglass was installed should be reporting through its hooks within
        // 30 s. If it isn't, say so on the row (and once in the log): the 0.17-0.20.3 bug went unnoticed for hours.
        if let installed = installedAt {
            for (id, var s) in merged where s.source == "registry" {
                if let st = s.started, st > installed, now - st > 30 {
                    s.hooksMissing = true; merged[id] = s
                    if !reportedMissing.contains(id) { reportedMissing.insert(id); onLog?("hooks not reporting: \(s.displayTitle) (\(id))") }
                }
            }
        }

        var out: [Session] = []
        var older = 0
        for s in merged.values {
            let recent = now - (s.updated ?? 0) <= Store.recentWindow
            // Registry status can be stale for long-idle sessions, so registry-only rows always need recent activity.
            if !recent && (s.source == "registry" || (s.state != "working" && s.state != "waiting")) { older += 1; continue }
            if let h = hidden[s.id], (s.updated ?? 0) <= h { continue }
            out.append(s)
        }
        if older != olderIdle { olderIdle = older }
        // Stable order: by state group, then by when the session started (not last update, which changes constantly).
        out.sort { ($0.rank, $0.started ?? 0, $0.id) < ($1.rank, $1.started ?? 0, $1.id) }
        for s in out where lastState[s.id] != nil && lastState[s.id] != s.state {
            if !muted, soundNeeds, s.state == "waiting" { NSSound(named: "Ping")?.play() }
            if !muted, soundDone, s.state == "done" { NSSound(named: "Glass")?.play() }
            if s.state == "done" { justDone[s.id] = now }   // shown under a collapsed header until seen
        }
        // A session newly needs you (or one already does when Spyglass starts): bring a hidden panel back.
        // The Store's first reload runs before the app sets onNeedsYou, so "already waiting at start" counts from then.
        if autoShow, let wake = onNeedsYou {
            let prev = wakePrimed ? lastState : [:]
            wakePrimed = true
            if let first = out.first(where: { $0.state == "waiting" && prev[$0.id] != "waiting" }) { wake(first) }
        }
        lastState = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0.state) })
        // An opened "Needs you" line folds away once that session no longer needs you.
        let stillWaiting = Set(out.filter { $0.state == "waiting" }.map(\.id))
        if !peekOpen.isSubset(of: stillWaiting) { peekOpen.formIntersection(stillWaiting) }
        // Forget a finished session once it moves on (new prompt), disappears, or after 15 minutes.
        let pruned = justDone.filter { id, at in now - at < Store.justDoneFor && out.contains { $0.id == id && $0.state == "done" } }
        if pruned != justDone { justDone = pruned }
        checkContext(out)
        trackWaits(out, now: now)
        if watcher != nil { scheduleTick() }
        pruneParsed()
        if out != sessions { sessions = out }
        resolveSwitches(out, now: now)
        resolveReplies(out, now: now)
        resolveRenames(out, now: now)
        if !textReplies.isEmpty {
            var next = textReplies
            for (id, r) in textReplies {
                let s = out.first { $0.id == id }
                if r.failed != nil ? now - r.since > 6 : (s == nil || s!.state != "waiting" || now - r.since > 15) { next[id] = nil }
            }
            if next != textReplies { textReplies = next }
        }
        if !answers.isEmpty {
            var next = answers
            for (id, a) in answers {
                let s = out.first { $0.id == id }
                let gone = s == nil || s!.question == nil || s!.state != "waiting"
                if a.failed != nil ? now - a.since > 6 : (gone || now - a.since > 10) { next[id] = nil }
            }
            if next != answers { answers = next }
        }
    }

    private func resolveReplies(_ live: [Session], now: Double) {
        guard !replies.isEmpty else { return }
        var next = replies
        for (id, r) in replies {
            guard let s = live.first(where: { $0.id == id }) else { next[id] = nil; continue }
            let answered = s.state != "waiting" || s.permission?.at != r.at
            if r.failed != nil ? now - r.since > 6 : (answered || now - r.since > 10) { next[id] = nil }
        }
        if next != replies { replies = next }
    }

    /// Answers a pending permission prompt: "1" (Yes, once) or Esc (No). send.sh re-checks it is still pending.
    /// Allow / Deny is possible: through the hook (any host, when the prompt has a fingerprint) or by keys.
    func canAnswerPermission(_ s: Session) -> Bool { s.permission?.key != nil || caps(s).pressKeys }

    func reply(_ s: Session, approve: Bool) {
        guard s.state == "waiting", let perm = s.permission, replies[s.id] == nil, canAnswerPermission(s) else { return }
        if approve && (perm.riskReason != nil || !panelAllow) { return }   // risky, or Allow turned off: terminal only
        let now = Date().timeIntervalSince1970
        replies[s.id] = Reply(approve: approve, at: perm.at, since: now, failed: nil)
        if let key = perm.key {
            // answer.sh (the PermissionRequest hook) is waiting for this: no keystrokes, works in any host.
            writeAnswer(s.id, key: key, approve: approve)
            // If nothing took it (the hook had stopped waiting, e.g. the panel restarted), fall back to keys.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Store.snapshotMode ? 0 : 3)) { [weak self] in
                guard let self, !Store.snapshotMode, let r = self.replies[s.id], r.failed == nil, r.at == perm.at,
                      let cur = self.sessions.first(where: { $0.id == s.id }), cur.permission?.at == perm.at else { return }
                try? FileManager.default.removeItem(at: Store.home.appendingPathComponent("answers/\(s.id).json"))
                if self.caps(cur).pressKeys { self.replyByKeys(cur, approve: approve, perm: perm) }
                else { self.replies[s.id] = Reply(approve: approve, at: perm.at, since: Date().timeIntervalSince1970,
                                                  failed: "Didn't reach the session: answer in \(self.caps(cur).app)") }
            }
        } else {
            replyByKeys(s, approve: approve, perm: perm)
        }
    }

    /// Spyglass's answer for answer.sh: {key, behavior}; the hook accepts it only for the prompt with that fingerprint.
    func writeAnswer(_ sid: String, key: String, approve: Bool) {
        let dir = Store.home.appendingPathComponent("answers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = ["key": key, "behavior": approve ? "allow" : "deny"]
        if let d = try? JSONSerialization.data(withJSONObject: body) {
            try? d.write(to: dir.appendingPathComponent("\(sid).json"), options: .atomic)
        }
    }

    private func replyByKeys(_ s: Session, approve: Bool, perm: Permission) {
        guard caps(s).pressKeys else { return }
        runSend(s, approve ? "key:approve" : "key:deny", extra: [s.id, String(format: "%.0f", perm.at)]) { [weak self] code in
            let why = code == 4 ? "Prompt already answered" : code == 2 ? Store.noReply(s) : "Couldn't reach the terminal"
            self?.replies[s.id] = Reply(approve: approve, at: perm.at, since: Date().timeIntervalSince1970, failed: why)
        }
    }

    // MARK: Replies to questions asked in text

    /// Reply typed from the panel, in flight (or just failed).
    @Published var textReplies: [String: Rename] = [:]
    @Published var replying: String? = nil   // session whose reply box is open

    func canReply(_ s: Session) -> Bool { s.asked != nil && s.permission == nil && s.question == nil && caps(s).typeText }

    /// "Should I…", "Shall I…", "Do you want…": a yes / no question gets Yes and No buttons.
    static func isYesNo(_ q: String) -> Bool {
        // Judge the sentence that asks ("The docs are ready. Should I also…?" -> "Should I also…?").
        var ask = q
        if let r = q.range(of: #"[^.!?]*\?\s*$"#, options: .regularExpression) { ask = String(q[r]).trimmingCharacters(in: .whitespaces) }
        let first = ask.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return ["should", "shall", "do", "does", "did", "can", "could", "would", "will", "is", "are", "want", "ok", "okay"].contains(first)
            || ask.lowercased().contains("go ahead") || ask.lowercased().contains("want me to")
    }

    func beginReply(_ s: Session) { guard canReply(s) else { return }; replying = s.id; onEditFocus?(true) }
    func endReply() { guard replying != nil else { return }; replying = nil; onEditFocus?(false) }

    /// Types the reply into the session (send.sh re-checks it still waits on you with nothing else open).
    func sendReply(_ s: Session, _ raw: String) {
        endReply()
        let text = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("/"), text.count <= 500, canReply(s), textReplies[s.id] == nil else { return }
        textReplies[s.id] = Rename(name: text, since: Date().timeIntervalSince1970, failed: nil)
        runSend(s, "reply:\(text)", extra: [s.id]) { [weak self] code in
            let why = code == 4 ? "It's no longer waiting for a reply" : code == 2 ? Store.noReply(s) : "Couldn't reach the terminal"
            self?.textReplies[s.id] = Rename(name: text, since: Date().timeIntervalSince1970, failed: why)
        }
    }

    /// Picks option `index` (0-based) of Claude's pending question: types its number. send.sh re-checks it is still pending.
    func answer(_ s: Session, _ index: Int) {
        guard s.state == "waiting", let q = s.question, let opts = q.options, index < opts.count, answers[s.id] == nil,
              caps(s).pressKeys else { return }
        let now = Date().timeIntervalSince1970
        answers[s.id] = Rename(name: opts[index], since: now, failed: nil)
        runSend(s, "answer:\(index + 1)", extra: [s.id, String(format: "%.0f", q.at)]) { [weak self] code in
            let why = code == 4 ? "Question already answered" : code == 2 ? Store.noReply(s) : "Couldn't reach the terminal"
            self?.answers[s.id] = Rename(name: opts[index], since: Date().timeIntervalSince1970, failed: why)
        }
    }

    /// Runs send.sh for a session; onFail gets the non-zero exit code on the main queue.
    private func runSend(_ s: Session, _ command: String, extra: [String] = [], onFail: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let pid: String = s.pid.map { String($0) } ?? ""
        var args: [String] = [Store.home.appendingPathComponent("send.sh").path]
        args += [s.term ?? "", s.tty ?? "", s.bundle ?? ""]
        args += [s.cmuxWorkspace ?? "", s.cmuxSurface ?? "", pid, command]
        p.arguments = args + extra
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            if code != 0 {
                DispatchQueue.main.async {
                    // In the log for /spyglass:doctor: a run of failures often means Claude Code changed a dialog.
                    self?.onLog?("action failed: \(command.prefix(40)) (exit \(code)) in \(s.displayTitle) [\(s.term ?? "-")]")
                    onFail(code)
                }
            }
        }
        do { try p.run() } catch { onFail(1) }
    }

    private func resolveSwitches(_ live: [Session], now: Double) {
        guard !switching.isEmpty else { return }
        var next = switching
        for (id, sw) in switching {
            guard let s = live.first(where: { $0.id == id }) else { next[id] = nil; continue }
            if sw.failed != nil {
                if now - sw.since > 8 { next[id] = nil }
            } else if (s.model ?? "").lowercased().contains(sw.alias) {
                next[id] = nil
            } else if now - sw.since > 15 {
                next[id] = ModelSwitch(alias: sw.alias, since: now, failed: "Didn't switch")
            }
        }
        if next != switching { switching = next }
    }

    /// Types `/model <alias>` into the session's terminal (idle or done sessions only).
    func switchModel(_ s: Session, to alias: String) {
        guard ModelSwitch.aliases.contains(alias), s.state == "idle" || s.state == "done", caps(s).typeText else { return }
        let now = Date().timeIntervalSince1970
        switching[s.id] = ModelSwitch(alias: alias, since: now, failed: nil)
        confirming[s.id] = nil
        runSend(s, "/model \(alias)", extra: [s.id]) { [weak self] code in
            let why = code == 2 ? Store.noReply(s) : code == 1 ? "Didn't switch: check the session's terminal" : "Couldn't reach the terminal"
            self?.switching[s.id] = ModelSwitch(alias: alias, since: Date().timeIntervalSince1970, failed: why)
        }
    }

    private func checkContext(_ live: [Session]) {
        var crossed = false
        for s in live {
            guard let c = s.ctx else { continue }
            if c >= Store.ctxWarnAt, !ctxWarned.contains(s.id) { ctxWarned.insert(s.id); crossed = true }
            else if c < Store.ctxRearmAt { ctxWarned.remove(s.id) }
        }
        ctxWarned.formIntersection(live.map(\.id))
        // No sound for sessions already past the mark when Spyglass starts.
        if crossed, ctxPrimed, !muted { NSSound(named: "Funk")?.play() }
        ctxPrimed = true
    }

    /// Why send.sh / resume.sh got no answer (exit 2), in words the user can act on.
    static func noReply(_ s: Session) -> String {
        s.term == "vscode"
            ? "Cursor / VS Code didn't answer: reload that window (Developer: Reload Window), or run /spyglass:editor"
            : "Can't type into this terminal (supported: iTerm2, Cursor / VS Code)"
    }

    // MARK: Welcome (first run)

    @Published var showWelcome: Bool = !UserDefaults.standard.bool(forKey: "welcomed")
    func dismissWelcome() { showWelcome = false; UserDefaults.standard.set(true, forKey: "welcomed") }
    func reopenWelcome() { showWelcome = true }

    static var userHome: String { ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() }

    /// Setup checklist, read live from disk.
    struct SetupState: Equatable { var stats: Bool; var editors: [String]; var editorExtension: Bool }
    func setupState() -> SetupState { Store.setupState() }
    static func setupState() -> SetupState {
        let fm = FileManager.default, home = Store.userHome
        // Model / context / usage: the statusline is feeding Spyglass (a recent stats file, or a statusline that calls it).
        var stats = false
        let statsDir = Store.home.appendingPathComponent("stats")
        for u in (try? fm.contentsOfDirectory(at: statsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(d) < 7 * 86400 { stats = true; break }
        }
        if !stats, let d = fm.contents(atPath: home + "/.claude/settings.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let cmd = (o["statusLine"] as? [String: Any])?["command"] as? String {
            if cmd.contains("spyglass/statusline.sh") { stats = true }
            else {
                let first = cmd.split(separator: " ").first.map(String.init) ?? ""
                let file = first.hasPrefix("~") ? home + first.dropFirst() : first
                if let t = try? String(contentsOfFile: file.replacingOccurrences(of: "\"", with: ""), encoding: .utf8),
                   t.contains("spyglass/stats.sh") { stats = true }
            }
        }
        // Editors installed, and whether the Spyglass Focus extension is in any of them.
        var editors: [String] = []
        for (app, name) in [("Cursor", "Cursor"), ("Visual Studio Code", "VS Code"), ("Windsurf", "Windsurf")]
        where fm.fileExists(atPath: "/Applications/\(app).app") || fm.fileExists(atPath: home + "/Applications/\(app).app") {
            editors.append(name)
        }
        var ext = false
        for dir in [".cursor/extensions", ".vscode/extensions", ".windsurf/extensions"] {
            if ((try? fm.contentsOfDirectory(atPath: home + "/" + dir)) ?? []).contains(where: { $0.hasPrefix("local.spyglass-focus-") }) { ext = true }
        }
        return SetupState(stats: stats, editors: editors, editorExtension: ext)
    }

    /// The question the session's last reply ends with, read from the end of its transcript (cached by file size).
    private var endings: [String: (size: UInt64, asked: Asked?, line: String?)] = [:]
    func endingQuestion(_ s: Session) -> Asked? { lastReply(s).asked }
    /// The end of the session's last reply, read from the transcript: a question it asks, and its last line.
    func lastReply(_ s: Session) -> (asked: Asked?, line: String?) {
        guard let url = transcriptURL(s.id, cwd: s.cwd),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return (nil, nil) }
        if let c = endings[s.id], c.size == size { return (c.asked, c.line) }
        var found: Asked? = nil, line: String? = nil
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let data = (try? fh.readToEnd()) ?? Data()
            // The last line that is the assistant speaking; the turn's final words are its last text block.
            for row in data.split(separator: 0x0A).reversed() {
                guard let o = try? JSONSerialization.jsonObject(with: row) as? [String: Any] else { continue }
                let type = o["type"] as? String
                if type == "user", let m = o["message"] as? [String: Any], m["content"] is String { break }   // you replied
                guard type == "assistant", let m = o["message"] as? [String: Any],
                      let blocks = m["content"] as? [[String: Any]] else { continue }
                if blocks.contains(where: { ($0["type"] as? String) == "tool_use" }) { break }   // still working, not a final reply
                guard let text = blocks.last(where: { ($0["type"] as? String) == "text" })?["text"] as? String else { continue }
                line = CLI.lastLine(text)
                if let q = CLI.endingQuestion(text) {
                    let at = ((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970
                    found = Asked(text: q, at: at)
                }
                break
            }
        }
        endings[s.id] = (size, found, line)
        return (found, line)
    }

    /// When this Spyglass version was installed (the version file's time), for the hooks self-check.
    lazy var installedAt: Double? = (try? FileManager.default.attributesOfItem(atPath: Store.home.appendingPathComponent("version").path))
        .flatMap { $0[.modificationDate] as? Date }?.timeIntervalSince1970
    private var reportedMissing: Set<String> = []
    var onLog: ((String) -> Void)?

    /// The installed Spyglass version (launch.sh writes it next to the panel).
    lazy var installedVersion: String? = (try? String(contentsOf: Store.home.appendingPathComponent("version"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    static func older(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p < q } }
        return false
    }
    /// The session runs hooks older than the installed Spyglass (or none): a restart brings the newest features.
    func oldHooks(_ s: Session) -> Bool {
        guard s.hooksMissing != true, let cur = installedVersion, !cur.isEmpty else { return false }
        guard let h = s.hooks else { return true }
        return Store.older(h, than: cur)
    }

    // MARK: Hover text

    private var branches: [String: (branch: String?, checked: Double)] = [:]
    /// Git branch of a folder, read from .git/HEAD (cached 30 s; no git process).
    func branch(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let now = Date().timeIntervalSince1970
        if let c = branches[cwd], now - c.checked < 30 { return c.branch }
        var dir = URL(fileURLWithPath: cwd), found: String? = nil
        for _ in 0..<8 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let h = try? String(contentsOf: head, encoding: .utf8) {
                let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
                found = t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(8))
                break
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        branches[cwd] = (found, now)
        return found
    }

    static func ago(_ t: Double?) -> String? {
        guard let t else { return nil }
        let secs = Int(Date().timeIntervalSince1970 - t)
        return secs < 60 ? "\(max(secs, 0))s" : secs < 3600 ? "\(secs / 60)m" : secs < 86400 ? "\(secs / 3600)h \(secs % 3600 / 60)m" : "\(secs / 86400)d"
    }

    static func clock(_ t: Double?) -> String? {
        guard let t else { return nil }
        let f = DateFormatter(); f.dateFormat = Date().timeIntervalSince1970 - t < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: Waiting on you

    /// Time sessions spent waiting on you today (waits.json survives restarts; it starts over at midnight).
    struct Waits: Codable, Equatable { var day = ""; var total: Double = 0; var sessions: [String: Double] = [:] }
    @Published var waits: Waits = {
        let f = Store.home.appendingPathComponent("waits.json")
        return (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(Waits.self, from: $0) } ?? Waits()
    }()
    @Published var waitStart: [String: Double] = [:]
    static func dayKey(_ t: Double) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date(timeIntervalSince1970: t)) }
    static func midnight(_ t: Double) -> Double { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970 }

    /// When the session started waiting: the prompt / question it's waiting on, else when the panel first saw it.
    private func waitSince(_ s: Session, now: Double) -> Double {
        if let t = s.asked?.at, t > 1_000_000_000 { return t }
        if let t = s.permission?.at, t > 1_000_000_000 { return t }
        if let t = s.question?.at, t > 1_000_000_000 { return t }
        return now
    }

    private func trackWaits(_ live: [Session], now: Double) {
        var w = waits
        if w.day != Store.dayKey(now) { w = Waits(day: Store.dayKey(now)) }
        let waiting = Dictionary(uniqueKeysWithValues: live.filter { $0.state == "waiting" }.map { ($0.id, $0) })
        for (id, s) in waiting where waitStart[id] == nil { waitStart[id] = waitSince(s, now: now) }
        let today = Store.midnight(now)
        for (id, start) in waitStart where waiting[id] == nil {
            let d = max(0, now - max(start, today))
            w.total += d; w.sessions[id, default: 0] += d
            waitStart[id] = nil
        }
        if w != waits {
            waits = w
            if let d = try? JSONEncoder().encode(w) { try? d.write(to: Store.home.appendingPathComponent("waits.json"), options: .atomic) }
        }
    }

    /// How long this session has been waiting on you now.
    func waitingFor(_ s: Session) -> Double? {
        guard s.state == "waiting", let st = waitStart[s.id] else { return nil }
        return max(0, Date().timeIntervalSince1970 - st)
    }
    /// Today's total, including waits still going on.
    var waitedToday: Double {
        let now = Date().timeIntervalSince1970, today = Store.midnight(now)
        let current = waitStart.values.reduce(0) { $0 + max(0, now - max($1, today)) }
        return (waits.day == Store.dayKey(now) ? waits.total : 0) + current
    }
    static func duration(_ secs: Double) -> String {
        let m = Int(secs / 60)
        return m < 1 ? "<1m" : m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    func stateLine(_ s: Session) -> String {
        switch s.state {
        case "working": return "Working for \(Store.ago(s.turnStarted ?? s.started) ?? "a moment")"
        case "waiting":
            if let q = s.question { return "Needs you: Claude asks \"\(q.text)\"" }
            if let a = s.asked { return "Needs you: Claude asked \"\(a.text)\"" }
            if let p = s.permission { return "Needs you: wants to use \(p.tool ?? "a tool")" }
            return "Needs you: \(s.activity ?? "waiting for your input")"
        case "done": return "Done \(Store.ago(s.updated).map { "\($0) ago" } ?? "")"
        default: return "Idle"
        }
    }

    func contextHelp(_ s: Session) -> String? {
        guard let c = s.ctx else { return nil }
        var t = "Context window: \(c)% used"
        if let n = s.ctxTokens, let z = s.ctxSize { t += " (\(compactTokens(n)) of \(compactTokens(z)) tokens)" }
        t += ".\nClaude Code compacts the conversation automatically when it fills."
        t += s.contextFull ? "\nNearly full: run /compact at a good stopping point, or start a fresh session." : "\nSpyglass warns at \(Store.ctxWarnAt)%."
        return t
    }

    func terminalLabel(_ s: Session) -> String {
        let c = caps(s)
        if s.entrypoint == "claude-vscode" { return "the Claude panel in \(c.app)" }
        if let n = s.tabName { return "\(c.app) tab “\(n)”" }
        return c.app
    }

    /// Everything about a session in one tooltip.
    func rowHelp(_ s: Session) -> String {
        var lines = [s.displayTitle, stateLine(s)]
        if s.state == "working", let a = s.activity, !a.isEmpty { lines.append("Now: \(a)") }
        if let w = waitingFor(s) {
            let total = (waits.day == Store.dayKey(Date().timeIntervalSince1970) ? waits.sessions[s.id] ?? 0 : 0) + w
            lines.append("Waiting on you for \(Store.duration(w)) · \(Store.duration(total)) today")
        }
        if let p = s.prompt, !p.isEmpty { lines.append("Last prompt: “\(p)”") }
        if s.state == "done", let l = s.lastLine { lines.append("Claude's last line: “\(l)”") }
        if let total = s.total, total > 0 { lines.append("Steps: \(s.done ?? 0) of \(total) done") }
        if let cwd = s.cwd {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            lines.append("Folder: \(path)" + (branch(cwd).map { " · ⎇ \($0)" } ?? ""))
        }
        var m: [String] = []
        if let model = s.model { m.append(model) }
        if let c = s.ctx { m.append("context \(c)%" + (s.ctxTokens.map { " (\(compactTokens($0)) tokens)" } ?? "")) }
        if !m.isEmpty { lines.append("Model: " + m.joined(separator: " · ")) }
        let u = usageHelp(s); if !u.isEmpty { lines.append(u) }
        var t: [String] = []
        if let st = Store.clock(s.started) { t.append("Started \(st)") }
        t.append("in \(terminalLabel(s))")
        lines.append(t.joined(separator: " "))
        if s.hooksMissing == true { lines.append("⚠︎ Hooks aren't reporting for this session: run /spyglass:doctor in it") }
        if let q = s.hooksQuiet {
            lines.append("⚠︎ No updates from this session's hooks since \(Store.clock(q) ?? "a while ago"), so its status may be old (last prompt is read from the conversation). Restart it (claude --resume)")
        }
        if oldHooks(s) { lines.append("Runs older Spyglass hooks\(s.hooks.map { " (\($0))" } ?? ""): restart it (claude --resume) for the newest features") }
        return lines.joined(separator: "\n")
    }

    func endedHelp(_ s: Session) -> String {
        var lines = [s.displayTitle, "Ended \(Store.ago(s.ended).map { "\($0) ago" } ?? "")" + (Store.clock(s.ended).map { " (\($0))" } ?? "")]
        if let p = s.prompt, !p.isEmpty { lines.append("Last prompt: “\(p)”") }
        if let cwd = s.cwd { lines.append("Folder: \(cwd)") }
        let u = usageHelp(s); if !u.isEmpty { lines.append(u) }
        lines.append("Resume reopens it in a new \(terminalLabel(s)) tab with its full history.")
        return lines.joined(separator: "\n")
    }

    // MARK: Usage

    /// Past the 5-hour or weekly limit: with extra usage on, further use is billed at API prices.
    var overLimit: Bool { limits.contains { $0.isPlanWindow && $0.pct >= 100 } }
    /// Behind a Claude gateway with a spend cap: every dollar counts.
    var spendLimit: LimitWindow? { limits.first { $0.key == "spend_limit" } }
    /// Each session's cost when it was first seen past the limit (extra.json), so rows show only what was added since.
    private lazy var extraBase: [String: Double] = {
        guard let d = try? Data(contentsOf: Store.home.appendingPathComponent("extra.json")),
              let o = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return o
    }()

    private func trackExtraUsage(_ sessions: [String: Session]) {
        var next = extraBase
        if overLimit {
            for (id, s) in sessions where next[id] == nil { if let c = s.cost { next[id] = c } }
        } else {
            next = [:]   // limits renewed (or never crossed): nothing extra
        }
        guard next != extraBase else { return }
        extraBase = next
        if let d = try? JSONEncoder().encode(next) { try? d.write(to: Store.home.appendingPathComponent("extra.json"), options: .atomic) }
    }

    func extraCost(_ s: Session) -> Double? {
        guard overLimit, let c = s.cost else { return nil }
        return max(0, c - (extraBase[s.id] ?? c))
    }

    /// Subscription: tokens used (the $ is only an API-price estimate). API key: the $ is the real bill.
    func usageLabel(_ s: Session) -> String? {
        if spendLimit != nil, let c = s.cost { return String(format: "$%.2f", c) }
        if let x = extraCost(s), x >= 0.01 { return String(format: "$%.2f extra", x) }   // tokens until something is added
        if !limits.isEmpty || s.cost == nil { return s.tokens.map { "\(compactTokens($0.used)) tok" } }
        return s.cost.map { String(format: "$%.2f", $0) }
    }

    func usageHelp(_ s: Session) -> String {
        var lines: [String] = []
        if let t = s.tokens {
            lines.append("Tokens this session: \(compactTokens(t.used)) new (input \(compactTokens(t.input)) · output \(compactTokens(t.output)) · cache write \(compactTokens(t.cacheWrite)))")
            lines.append("Cache re-reads: \(compactTokens(t.cacheRead))")
        }
        if let x = extraCost(s) {
            lines.append(String(format: "Since passing your limit: $%.2f at API prices (billed only if extra usage is on)", x))
        }
        if let c = s.cost {
            lines.append(limits.isEmpty || spendLimit != nil ? String(format: "Cost: $%.2f", c)
                                        : String(format: "API-price estimate: $%.2f (not a bill on a subscription)", c))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Rename

    func canRename(_ s: Session) -> Bool { caps(s).typeText && s.pid != nil && (s.state == "idle" || s.state == "done") }

    // MARK: Where a session runs

    private var appNames: [String: String] = [:]
    /// Names for apps Claude runs in, known without asking macOS (which only knows installed apps).
    static let knownApps: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.exafunction.windsurf": "Windsurf", "com.vscodium": "VSCodium", "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal", "com.anthropic.claudefordesktop": "Claude", "com.cmuxterm.app": "cmux",
        "com.mitchellh.ghostty": "Ghostty", "dev.warp.Warp-Stable": "Warp", "net.kovidgoyal.kitty": "kitty",
        "com.github.wez.wezterm": "WezTerm", "com.jetbrains.intellij": "IntelliJ IDEA", "com.jetbrains.intellij.ce": "IntelliJ IDEA CE",
        "com.jetbrains.pycharm": "PyCharm", "com.jetbrains.WebStorm": "WebStorm", "com.jetbrains.goland": "GoLand",
    ]
    func appName(_ bundle: String?) -> String? {
        guard let b = bundle, !b.isEmpty else { return nil }
        if let n = Store.knownApps[b] { return n }
        if let n = appNames[b] { return n }
        var name = b
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        appNames[b] = name
        return name
    }

    /// Typing works in iTerm2 and Cursor / VS Code terminals; Terminal.app takes text commands but not single keys
    /// (`do script` adds Enter); the Claude extension panel, desktop app, JetBrains and cmux can only be jumped to.
    func caps(_ s: Session) -> Caps {
        let entry = s.entrypoint ?? "cli"
        if entry == "claude-desktop" { return Caps(app: "Claude", typeText: false, pressKeys: false, resume: true) }
        if entry == "claude-vscode" {
            return Caps(app: appName(s.bundle) ?? "your editor", typeText: false, pressKeys: false, resume: true)
        }
        if entry.contains("jetbrains") || (s.bundle ?? "").hasPrefix("com.jetbrains") || s.term == "JetBrains-JediTerm" {
            return Caps(app: appName(s.bundle) ?? "JetBrains", typeText: false, pressKeys: false, resume: true)
        }
        if s.cmuxWorkspace != nil || s.bundle == "com.cmuxterm.app" {
            return Caps(app: "cmux", typeText: false, pressKeys: false, resume: true)
        }
        switch s.term {
        case "iTerm.app": return Caps(app: "iTerm2", typeText: true, pressKeys: true, resume: true)
        case "vscode": return Caps(app: appName(s.bundle) ?? "Cursor / VS Code", typeText: true, pressKeys: true, resume: true)
        case "Apple_Terminal": return Caps(app: "Terminal", typeText: true, pressKeys: false, resume: true)
        default:
            // Known only from the registry (no hook data yet): send.sh works the host out from the process tree.
            if s.term == nil && s.source == "registry" { return Caps(app: "its terminal", typeText: true, pressKeys: true, resume: true) }
            return Caps(app: appName(s.bundle) ?? s.term ?? "its app", typeText: false, pressKeys: false, resume: true)
        }
    }

    func beginRename(_ s: Session) {
        guard canRename(s) else { return }
        editing = s.id
        onEditFocus?(true)
    }

    func endRename() {
        guard editing != nil else { return }
        editing = nil
        onEditFocus?(false)
    }

    /// /rename the session and rename its terminal tab (send.sh validates: one line, 1-80 chars, no control characters).
    func rename(_ s: Session, to raw: String) {
        endRename()
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        var name = cleaned
        while name.utf8.count > 80 { name.removeLast() }
        guard !name.isEmpty, name != s.displayTitle, canRename(s) else { return }
        let now = Date().timeIntervalSince1970
        renaming[s.id] = Rename(name: name, since: now, failed: nil)
        runSend(s, "rename:\(name)", extra: [s.id]) { [weak self] code in
            let why = code == 2 ? Store.noReply(s) : code == 3 ? "Name not allowed" : "Claude didn't take the new name"
            self?.renaming[s.id] = Rename(name: name, since: Date().timeIntervalSince1970, failed: why)
        }
    }

    private func resolveRenames(_ live: [Session], now: Double) {
        guard !renaming.isEmpty else { return }
        var next = renaming
        for (id, r) in renaming {
            guard let s = live.first(where: { $0.id == id }) else { next[id] = nil; continue }
            if r.failed != nil ? now - r.since > 6 : (s.displayTitle == r.name || now - r.since > 15) { next[id] = nil }
        }
        if next != renaming { renaming = next }
    }

    // MARK: Ended sessions / Resume

    /// Keeps an ended session for the Resume list, unless it never got a prompt or is already saved (SessionEnd hook).
    private func saveEnded(_ s: Session) {
        guard (s.prompt ?? s.title) != nil, s.cwd != nil else { return }
        let url = endedDir.appendingPathComponent("\(s.id).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var e = s
        e.ended = Date().timeIntervalSince1970
        e.permission = nil
        try? FileManager.default.createDirectory(at: endedDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: url, options: .atomic) }
    }

    private func loadEnded(live: Set<String>, now: Double) {
        let fm = FileManager.default
        var out: [Session] = []
        for url in (try? fm.contentsOfDirectory(at: endedDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            guard let e = cachedSession(url) else {
                try? fm.removeItem(at: url); continue
            }
            // Resumed (same id is live again) or too old: drop it.
            if live.contains(e.id) || now - (e.ended ?? 0) > Store.endedWindow { try? fm.removeItem(at: url); continue }
            out.append(e)
        }
        out.sort { ($0.ended ?? 0) > ($1.ended ?? 0) }
        let shown = Array(out.prefix(Store.endedMax))
        if shown != ended { ended = shown }
        for (id, r) in resuming where r.failed != nil ? now - r.since > 6 : (live.contains(id) || now - r.since > 15) {
            resuming[id] = nil
        }
    }

    func resume(_ s: Session) {
        guard resuming[s.id] == nil else { return }
        resuming[s.id] = (Date().timeIntervalSince1970, nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let term = s.entrypoint == "claude-vscode" ? "vscode" : (s.term ?? "")   // panel sessions reopen in the editor's terminal
        p.arguments = [Store.home.appendingPathComponent("resume.sh").path, term, s.bundle ?? "", s.cwd ?? "", s.id]
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            guard code != 0 else { return }
            let why = code == 5 ? "Folder no longer exists" : code == 2 ? Store.noReply(s) : "Couldn't open a terminal"
            DispatchQueue.main.async { self?.resuming[s.id] = (Date().timeIntervalSince1970, why) }
        }
        do { try p.run() } catch { resuming[s.id] = (Date().timeIntervalSince1970, "Couldn't run resume.sh") }
    }

    func dismissEnded(_ s: Session) {
        try? FileManager.default.removeItem(at: endedDir.appendingPathComponent("\(s.id).json"))
        ended.removeAll { $0.id == s.id }
    }
    func clearEnded() { ended.forEach(dismissEnded) }
    func toggleEnded() { showEnded.toggle(); UserDefaults.standard.set(showEnded, forKey: "showEnded") }

    func hide(_ s: Session) { hidden[s.id] = s.updated ?? 0; reload() }
    var onHidePanel: (() -> Void)?

    // MARK: Settings (⚙ menu)
    private static func pref(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
    @Published var soundDone: Bool = Store.pref("soundDone", true)     // chime when a session finishes
    @Published var soundNeeds: Bool = Store.pref("soundNeeds", true)   // ping when a session needs you
    @Published var autoShow: Bool = Store.pref("autoShow", true)       // a hidden panel comes back when a session needs you
    @Published var hotkeys: Bool = Store.pref("hotkeys", true)         // ⌃⌥S show / hide, ⌃⌥J jump to who's waiting longest
    var onHotkeysChanged: ((Bool) -> Void)?

    /// ⌃⌥J: the session that has waited on you longest (oldest "Needs you").
    var longestWaiting: Session? {
        func since(_ s: Session) -> Double {
            if let t = s.asked?.at { return t }
            if let t = s.permission?.at { return t }
            if let t = s.question?.at { return t }
            return s.updated ?? 0
        }
        return sessions.filter { $0.state == "waiting" }.min { since($0) < since($1) }
    }
    /// ⚙ → Allow from the panel (see Risk.panelAllow). Published so the cards redraw when it changes.
    @Published var panelAllow: Bool = Risk.panelAllow
    func setPanelAllow(_ on: Bool) { Risk.setPanelAllow(on); panelAllow = on }

    func setPref(_ k: String, _ v: Bool) {
        UserDefaults.standard.set(v, forKey: k)
        switch k {
        case "soundDone": soundDone = v; case "soundNeeds": soundNeeds = v; case "autoShow": autoShow = v
        case "hotkeys": hotkeys = v; onHotkeysChanged?(v)
        default: break
        }
    }
    var startsAtLogin: Bool {
        FileManager.default.fileExists(atPath: Store.userHome + "/Library/LaunchAgents/dev.spyglass.panel.plist")
    }
    func setStartAtLogin(_ on: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Store.home.appendingPathComponent("login.sh").path, on ? "on" : "off"]
        try? p.run()
        objectWillChange.send()
    }
    /// Sessions that just finished (the chime), by id -> when. Collapsed, the panel lists them so you see which one rang.
    @Published var justDone: [String: Double] = [:]
    static let justDoneFor: Double = 15 * 60

    /// Collapsed view: "Needs you" lines opened in place to their full row (to answer without expanding everything).
    @Published var peekOpen: Set<String> = []
    func togglePeek(_ s: Session) { if peekOpen.contains(s.id) { peekOpen.remove(s.id) } else { peekOpen.insert(s.id) } }

    /// Collapsed view: sessions that need you, then the ones that just finished (newest first).
    var peek: [Session] {
        let now = Date().timeIntervalSince1970
        let waiting = sessions.filter { $0.state == "waiting" }
        let done = sessions.filter { s in s.state == "done" && justDone[s.id].map { now - $0 < Store.justDoneFor } == true }
            .sorted { (justDone[$0.id] ?? 0) > (justDone[$1.id] ?? 0) }
        return Array((waiting + done).prefix(5))
    }
    /// Called when a session newly needs you; the app shows a hidden panel.
    var onNeedsYou: ((Session) -> Void)?
    private var wakePrimed = false
    func hidePanel() { onHidePanel?() }
    func toggleMute() { muted.toggle(); UserDefaults.standard.set(muted, forKey: "muted") }
    func toggleCompact() { compact.toggle(); UserDefaults.standard.set(compact, forKey: "compact") }

    /// Rows that stay full size in compact view: anything that needs you or is mid-action.
    func needsFullRow(_ s: Session) -> Bool {
        s.state == "waiting" || s.contextFull || confirming[s.id] != nil || editing == s.id
            || renaming[s.id] != nil || switching[s.id] != nil || replies[s.id] != nil || answers[s.id] != nil
    }

    /// Compact layout: full rows first, then one-line rows grouped by repo once there are 6+ sessions.
    // MARK: Search (the field above the list, from searchFrom sessions)

    static let searchFrom = 5
    @Published var query = ""
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Every word must appear (any case) in the tab name, title, folder, model or current activity.
    func matches(_ s: Session) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = [s.displayTitle, s.title ?? "", s.tabName ?? "", (s.cwd as NSString?)?.lastPathComponent ?? "",
                   s.model ?? "", s.activity ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
    /// The rows the list shows.
    var shown: [Session] { searching ? sessions.filter(matches) : sessions }
    var shownEnded: [Session] { searching ? ended.filter(matches) : ended }
    /// Sessions waiting on you that the search hides: never hidden silently.
    var hiddenWaiting: Int { searching ? sessions.filter { $0.state == "waiting" && !matches($0) }.count : 0 }

    func compactLayout() -> (full: [Session], groups: [(name: String, rows: [Session])]) {
        let sessions = shown
        let full = sessions.filter(needsFullRow)
        let rest = sessions.filter { !needsFullRow($0) }
        guard sessions.count >= 6 else { return (full, rest.isEmpty ? [] : [("", rest)]) }
        var order: [String] = []
        var byRepo: [String: [Session]] = [:]
        for s in rest {
            let repo = (s.cwd as NSString?)?.lastPathComponent ?? "other"
            if byRepo[repo] == nil { order.append(repo) }
            byRepo[repo, default: []].append(s)
        }
        return (full, order.sorted().map { ($0, byRepo[$0]!) })
    }

    func toggleCollapse() { collapsed.toggle(); UserDefaults.standard.set(collapsed, forKey: "collapsed") }

    func jump(_ s: Session) {
        justDone[s.id] = nil   // seen
        let script = Store.home.appendingPathComponent("focus.sh").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let pid: String = s.pid.map { String($0) } ?? ""
        var args: [String] = [script, s.term ?? "", s.tty ?? "", s.bundle ?? ""]
        args += [s.cmuxWorkspace ?? "", s.cmuxSurface ?? "", pid, s.entrypoint ?? "", s.cwd ?? ""]
        p.arguments = args
        try? p.run()
    }
}
