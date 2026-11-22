// Spyglass: floating panel listing live Claude Code sessions.
// Reads ~/.claude/spyglass/sessions/*.json written by the plugin's scripts/record.sh.
// Build: ../app/build.sh
import AppKit
import CryptoKit
import SwiftUI

// MARK: - Model

struct Session: Identifiable, Codable, Equatable {
    let id: String
    var title: String?
    var cwd: String?
    var status: String?
    var activity: String?
    var prompt: String?
    var done: Int?
    var total: Int?
    var steps: Int?
    var started: Double?
    var turnStarted: Double?
    var updated: Double?
    var pid: Int32?
    var tty: String?
    var term: String?
    var bundle: String?
    var cmuxWorkspace: String?
    var cmuxSurface: String?
    var source: String?          // "registry" when known only from Claude Code's session registry
    var permission: Permission?  // pending permission prompt (PermissionRequest hook)
    var question: Question?      // pending AskUserQuestion
    var asked: Asked?            // the turn ended with a question for you (in plain text)
    var lastLine: String?        // last line of Claude's final reply (finished turns)
    var hooks: String?           // Spyglass version of the hooks this session runs
    var entrypoint: String?      // cli, claude-vscode (extension panel), claude-desktop, claude-code-jetbrains-plugin
    var ended: Double?           // set on entries in ended/ (sessions offered for Resume)
    var model: String?           // from stats/<id>.json (statusline), not the hooks
    var ctx: Int?
    var cost: Double?
    var tokens: TokenTotals?
    var ctxTokens: Int?
    var ctxSize: Int?

    var state: String { status ?? "idle" }
    var contextFull: Bool { (ctx ?? 0) >= Store.ctxWarnAt }
    var titleSource: String?     // "custom" (/rename), "ai", "prompt"
    var tabName: String?         // the name you gave its Cursor / VS Code terminal tab
    /// Your /rename wins, then the Cursor tab name you gave it, then Claude's auto title.
    var displayTitle: String {
        if titleSource == "custom", let t = title, !t.isEmpty { return t }
        if let n = tabName, !n.isEmpty { return n }
        if let t = title, !t.isEmpty { return t }
        return (cwd as NSString?)?.lastPathComponent ?? "Claude session"
    }
    var rank: Int {
        switch state { case "waiting": return 0; case "working": return 1; case "done": return 2; default: return 3 }
    }
}

/// Tokens a session has used, summed from its transcript (each API response counted once).
struct TokenTotals: Codable, Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    /// New tokens: input + output + cache writes. Cache reads are cheap re-reads and shown separately.
    var used: Int { input + output + cacheWrite }
}

/// One plan limit window from the statusline (subscriptions only).
struct LimitWindow: Equatable {
    let key: String
    let pct: Double
    let resets: Double?
    var usd: Double? = nil        // spend_limit (Claude gateway): spent this period
    var limitUsd: Double? = nil
    var label: String {
        switch key {
        case "five_hour": return "5h"
        case "seven_day": return "Week"
        case "seven_day_opus": return "Opus week"
        case "seven_day_sonnet": return "Sonnet week"
        case "spend_limit": return "Spend"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }
    var left: Int { max(0, 100 - Int(pct.rounded())) }
    static let order = ["spend_limit", "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
    var isPlanWindow: Bool { key == "five_hour" || key == "seven_day" }
}

func compactTokens(_ n: Int) -> String {
    n < 1000 ? "\(n)" : n < 1_000_000 ? String(format: "%.0fk", Double(n) / 1000) : String(format: "%.1fM", Double(n) / 1_000_000)
}

func resetTime(_ t: Double) -> String {
    let d = Date(timeIntervalSince1970: t), f = DateFormatter()
    f.dateFormat = d.timeIntervalSinceNow < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}

/// Sums token usage from session transcripts on a background queue, reading only new bytes;
/// positions persist in tokens.json so a restart doesn't rescan 200 MB transcripts.
final class TokenCounter {
    struct Entry: Codable { var path: String; var offset: UInt64; var totals: TokenTotals; var recent: [String] }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "spyglass.tokens", qos: .utility)
    private var busy = false
    private let file: URL
    static var forceSynchronous = false   // test mode: set before the Store exists
    lazy var synchronous = TokenCounter.forceSynchronous

    init(home: URL) {
        file = home.appendingPathComponent("tokens.json")
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    func totals(_ id: String) -> TokenTotals? { lock.lock(); defer { lock.unlock() }; return entries[id]?.totals }

    func update(_ transcripts: [String: URL]) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        let work = { [self] in
            for (id, url) in transcripts { scan(id, url) }
            lock.lock()
            entries = entries.filter { transcripts[$0.key] != nil || FileManager.default.fileExists(atPath: $0.value.path) }
            let snapshot = entries
            busy = false
            lock.unlock()
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
        }
        if synchronous { work() } else { queue.async(execute: work) }
    }

    private func scan(_ id: String, _ url: URL) {
        lock.lock(); var e = entries[id] ?? Entry(path: url.path, offset: 0, totals: TokenTotals(), recent: []); lock.unlock()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < e.offset || e.path != url.path { e = Entry(path: url.path, offset: 0, totals: TokenTotals(), recent: []) }
        guard size > e.offset else { return }
        try? fh.seek(toOffset: e.offset)
        var carry = Data()
        while true {
            guard let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            var buf = carry + chunk
            guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; continue }
            carry = buf[buf.index(after: lastNL)...]
            buf = buf[buf.startIndex...lastNL]
            for line in buf.split(separator: 0x0A) where line.count > 40 {
                // Cheap filter before parsing: assistant responses carry "usage".
                guard line.range(of: Data("\"usage\"".utf8)) != nil,
                      let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
                // One response is written as several lines with the same message id: count it once.
                if let mid = m["id"] as? String {
                    if e.recent.contains(mid) { continue }
                    e.recent.append(mid); if e.recent.count > 200 { e.recent.removeFirst(e.recent.count - 200) }
                }
                e.totals.input += (u["input_tokens"] as? Int) ?? 0
                e.totals.output += (u["output_tokens"] as? Int) ?? 0
                e.totals.cacheWrite += (u["cache_creation_input_tokens"] as? Int) ?? 0
                e.totals.cacheRead += (u["cache_read_input_tokens"] as? Int) ?? 0
            }
            e.offset += UInt64(chunk.count)
        }
        e.offset -= UInt64(carry.count)   // re-read the unfinished last line next time
        lock.lock(); entries[id] = e; lock.unlock()
    }
}

/// Claude's pending multiple-choice question; options empty = too complex to answer from the panel.
struct Question: Codable, Equatable {
    var text: String
    var header: String?
    var options: [String]?
    var at: Double
}

/// What Spyglass can do for a session, from where it runs.
struct Caps: Equatable {
    let app: String       // "iTerm2", "Terminal", "Cursor", "Claude", ...
    let typeText: Bool    // /model, /rename
    let pressKeys: Bool   // Allow (1) / Deny (Esc) / question options
    let resume: Bool      // Resume reopens it (in its terminal, or a terminal app)
}

/// A turn that ended by asking you something in plain text: answered by replying in the session.
struct Asked: Codable, Equatable {
    var text: String
    var at: Double
}

struct Permission: Codable, Equatable {
    var tool: String?
    var detail: String?
    var at: Double
    var key: String?   // fingerprint of the tool call; set by hooks that let answer.sh take Spyglass's answer
}

/// An Allow / Deny click in flight (or just failed), by session id.
struct Reply: Equatable {
    let approve: Bool
    let at: Double          // the permission prompt it answers
    let since: Double
    let failed: String?
}

struct Rename: Equatable {
    let name: String
    let since: Double
    let failed: String?
}

struct ModelSwitch: Equatable {
    static let aliases = ["opus", "sonnet", "haiku"]
    let alias: String
    let since: Double
    let failed: String?
}

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
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/spyglass")
    }()
    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reload() }
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
    private let claudeDir: URL = {
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
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private func transcriptURL(_ sid: String, cwd: String?) -> URL? {
        if let u = transcriptPaths[sid] { return u }
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
        return nil
    }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970

        // Hook-recorded sessions: rich state (activity, progress, terminal location).
        var hooked: [String: Session] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? JSONDecoder().decode(Session.self, from: data) else { continue }
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
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
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

        // Sessions that vanished since the last reload (terminal closed, crash) are kept for Resume.
        for (id, s) in lastLive where merged[id] == nil { saveEnded(s) }
        lastLive = merged
        loadEnded(live: Set(merged.keys), now: now)

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
        // Forget a finished session once it moves on (new prompt), disappears, or after 15 minutes.
        let pruned = justDone.filter { id, at in now - at < Store.justDoneFor && out.contains { $0.id == id && $0.state == "done" } }
        if pruned != justDone { justDone = pruned }
        checkContext(out)
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
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            if code != 0 { DispatchQueue.main.async { onFail(code) } }
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
    func setupState() -> SetupState {
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
                   t.contains("spyglass/stats.sh") || t.contains("tower/stats.sh") { stats = true }
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
        guard let cur = installedVersion, !cur.isEmpty else { return false }
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
    func appName(_ bundle: String?) -> String? {
        guard let b = bundle, !b.isEmpty else { return nil }
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
            guard let data = try? Data(contentsOf: url), let e = try? JSONDecoder().decode(Session.self, from: data) else {
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
    func setPref(_ k: String, _ v: Bool) {
        UserDefaults.standard.set(v, forKey: k)
        switch k { case "soundDone": soundDone = v; case "soundNeeds": soundNeeds = v; case "autoShow": autoShow = v; default: break }
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
    func compactLayout() -> (full: [Session], groups: [(name: String, rows: [Session])]) {
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

// MARK: - Views

let accent = Color(red: 0.83, green: 0.95, blue: 0.36)
let palette: [Color] = [
    Color(red: 0.35, green: 0.53, blue: 0.98), Color(red: 0.95, green: 0.50, blue: 0.68),
    Color(red: 0.96, green: 0.64, blue: 0.33), Color(red: 0.60, green: 0.48, blue: 0.98),
    Color(red: 0.30, green: 0.78, blue: 0.66), Color(red: 0.93, green: 0.40, blue: 0.40),
]
func colorFor(_ id: String) -> Color {
    var h: UInt32 = 5381
    for b in id.utf8 { h = (h &* 33) &+ UInt32(b) }
    return palette[Int(h % UInt32(palette.count))]
}

struct Buddy: View {
    let color: Color
    let state: String
    @State private var blink = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(color).frame(width: 34, height: 38)
            VStack(spacing: 6) {
                HStack(spacing: 9) { eye; eye }
                mouth
            }.foregroundColor(Color.black.opacity(0.75))
            if state == "waiting" {
                Text("!").font(.system(size: 13, weight: .heavy)).foregroundColor(.orange)
                    .offset(x: 18, y: -20)
            }
        }
        .frame(width: 44, height: 46)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 3.2, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.12)) { blink = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.12)) { blink = false }
                }
            }
        }
    }
    @ViewBuilder var eye: some View {
        switch state {
        case "done": ArcEye().stroke(lineWidth: 2).frame(width: 7, height: 4)
        case "waiting": Circle().frame(width: 6, height: 6)
        case "working": Capsule().frame(width: 6, height: blink ? 1 : 6)
        default: Capsule().frame(width: 7, height: 2)
        }
    }
    @ViewBuilder var mouth: some View {
        switch state {
        case "done": ArcEye().stroke(lineWidth: 2).rotationEffect(.degrees(180)).frame(width: 10, height: 4)
        case "waiting": Circle().stroke(lineWidth: 2).frame(width: 6, height: 6)
        default: Capsule().frame(width: 10, height: 2)
        }
    }
}

struct ArcEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        return p
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(hover ? Color.white.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).foregroundColor(.white.opacity(0.75)).tip(help)
        .onHover { hover = $0 }
    }
}

/// The row's name; the pencil (on hover, idle sessions) edits it in place: Enter saves, Esc cancels.
struct NameField: View {
    let s: Session
    @ObservedObject var store: Store
    let hover: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if store.editing == s.id {
            TextField("Session name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                .focused($focused)
                .onAppear { draft = s.displayTitle; DispatchQueue.main.async { focused = true } }
                .onSubmit { store.rename(s, to: draft) }
                .onExitCommand { store.endRename() }
                .tip("Enter renames the session (/rename) and its terminal tab · Esc cancels")
        } else if let r = store.renaming[s.id] {
            HStack(spacing: 5) {
                Text(r.name).font(.system(size: 13, weight: .bold)).foregroundColor(.white.opacity(r.failed == nil ? 0.6 : 0.9))
                    .lineLimit(1)
                if let why = r.failed { Text("⚠︎").foregroundColor(.orange).tip(why) }
                else { Text("…").foregroundColor(.white.opacity(0.5)) }
            }
        } else {
            HStack(spacing: 4) {
                Text(s.displayTitle).font(.system(size: 13, weight: .bold)).foregroundColor(.white).lineLimit(1)
                if store.oldHooks(s) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                        .tip("Started before Spyglass \(store.installedVersion ?? "")\(s.hooks.map { " (runs \($0))" } ?? ""): restart it with claude --resume for the newest features")
                }
                if hover, store.canRename(s) {
                    Button { store.beginRename(s) } label: {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain).tip("Rename this session and its terminal tab")
                }
            }
        }
    }
}

struct Row: View {
    let s: Session
    @ObservedObject var store: Store
    @State private var hover = false

    var statusLine: (String, Color) {
        switch s.state {
        case "waiting": return ("Needs you", .orange)
        case "done": return ("Done", accent)
        case "working":
            if let t = s.total, t > 0 { return ("\(s.done ?? 0)/\(t) steps", accent) }
            return ("Working · \(elapsed)", accent)
        default: return ("Idle", .gray)
        }
    }
    var elapsed: String {
        let secs = Int(Date().timeIntervalSince1970 - (s.turnStarted ?? s.started ?? Date().timeIntervalSince1970))
        return secs < 60 ? "\(max(secs, 0))s" : secs < 3600 ? "\(secs / 60)m" : "\(secs / 3600)h \(secs % 3600 / 60)m"
    }
    var fraction: Double? {
        if let t = s.total, t > 0 { return Double(s.done ?? 0) / Double(t) }
        return s.state == "done" ? 1 : nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Buddy(color: colorFor(s.id), state: s.state).tip(store.rowHelp(s))
            VStack(alignment: .leading, spacing: 3) {
                NameField(s: s, store: store, hover: hover)
                Text(s.state == "done" ? (s.lastLine ?? s.activity ?? "") : s.asked != nil ? "Asked you" : (s.activity ?? ""))
                    .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(statusLine.0).font(.system(size: 11, weight: .semibold)).foregroundColor(statusLine.1)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(0).tip(store.stateLine(s))
                    Spacer(minLength: 4)
                    ModelPicker(s: s, store: store).layoutPriority(1)
                    if let c = s.ctx {
                        if s.contextFull {
                            Text("⚠︎ ctx \(c)%").foregroundColor(.red).fixedSize().layoutPriority(3)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.red.opacity(0.18)))
                                .tip(store.contextHelp(s) ?? "")
                        } else {
                            Text("ctx \(c)%").foregroundColor(c >= 60 ? .yellow : .green).fixedSize().layoutPriority(3)
                                .tip(store.contextHelp(s) ?? "")
                        }
                    }
                    if let u = store.usageLabel(s) {
                        Text(u).foregroundColor(.white.opacity(0.45)).fixedSize().layoutPriority(2).tip(store.usageHelp(s))
                    }
                }
                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if s.state == "waiting", s.question == nil, s.permission == nil, let a = s.asked {
                    AskedCard(s: s, asked: a, store: store)
                } else if s.state == "waiting", (s.question != nil && !store.caps(s).pressKeys)
                    || (s.question == nil && s.permission != nil && !store.canAnswerPermission(s)) {
                    AnswerThere(s: s, store: store)
                } else if s.state == "waiting", let q = s.question { QuestionCard(s: s, q: q, store: store) }
                else if s.state == "waiting", let perm = s.permission, perm.tool != "AskUserQuestion" {
                    PermissionCard(s: s, perm: perm, store: store)
                }
                if let a = store.confirming[s.id] { ModelConfirm(s: s, alias: a, store: store) }
                ProgressBar(fraction: fraction, active: s.state == "working",
                            color: s.state == "waiting" ? .orange : accent)
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                IconButton(symbol: "arrow.up.forward.square", help: "Jump to \(store.terminalLabel(s))") { store.jump(s) }
                IconButton(symbol: "xmark", help: "Hide until it does something new") { store.hide(s) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(s.state == "waiting" ? Color.orange.opacity(0.7) : s.contextFull ? Color.red.opacity(0.6) : Color.clear,
                    lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {   // a click anywhere outside the row's buttons goes there (not while typing in it)
            if store.editing != s.id && store.replying != s.id { store.jump(s) }
        }
        .tip(store.endedHelp(s))
    }
}

struct PermissionCard: View {
    let s: Session
    let perm: Permission
    @ObservedObject var store: Store
    var reply: Reply? { store.replies[s.id].flatMap { $0.at == perm.at ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let d = perm.detail, !d.isEmpty {
                Text(d).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85))
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                    .tip(d)
            }
            HStack(spacing: 8) {
                if let r = reply, let why = r.failed {
                    Text("⚠︎ \(why)").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                } else if let r = reply {
                    Text(r.approve ? "Allowing…" : "Denying…").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    ReplyButton(title: "Allow once", color: accent) { store.reply(s, approve: true) }
                        .tip("Approve this \(perm.tool ?? "tool") call once (same as pressing 1)")
                    ReplyButton(title: "Deny", color: .white.opacity(0.75)) { store.reply(s, approve: false) }
                        .tip("Decline it (same as pressing Esc)")
                }
                Spacer()
            }
        }
        .padding(.top, 2)
    }
}

/// Claude ended its turn with a question: show it, and jump to the session to reply.
struct AskedCard: View {
    let s: Session
    let asked: Asked
    @ObservedObject var store: Store
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(asked.text).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true).tip(asked.text)
            if let r = store.textReplies[s.id] {
                Text(r.failed.map { "⚠︎ \($0)" } ?? "Replying: \(r.name)…").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(r.failed == nil ? .white.opacity(0.6) : .orange).lineLimit(1)
            } else if store.replying == s.id {
                TextField("Reply to Claude…", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                    .focused($focused)
                    .onAppear { draft = ""; DispatchQueue.main.async { focused = true } }
                    .onSubmit { store.sendReply(s, draft) }
                    .onExitCommand { store.endReply() }
                    .tip("Enter sends it to the session · Esc cancels")
            } else if store.canReply(s) {
                HStack(spacing: 6) {
                    if Store.isYesNo(asked.text) {
                        ReplyButton(title: "Yes", color: accent) { store.sendReply(s, "yes") }.tip("Reply \"yes\"")
                        ReplyButton(title: "No", color: .white.opacity(0.8)) { store.sendReply(s, "no") }.tip("Reply \"no\"")
                    }
                    ReplyButton(title: "Reply…", color: .white.opacity(0.8)) { store.beginReply(s) }.tip("Type a one-line reply")
                    Spacer(minLength: 0)
                    IconButton(symbol: "arrow.up.forward.square", help: "Jump to \(store.terminalLabel(s))") { store.jump(s) }
                }
            } else {
                ReplyButton(title: "Reply in \(store.caps(s).app) ↗", color: accent) { store.jump(s) }
                    .tip("Jump to \(store.terminalLabel(s)) to answer")
            }
        }
        .padding(.top, 2)
    }
}

/// Where Spyglass can't press keys (Terminal.app, the Claude extension panel, desktop app, JetBrains, cmux):
/// show what's being asked and a one-click jump to answer it there.
struct AnswerThere: View {
    let s: Session
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let q = s.question {
                Text(q.text).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
            } else if let d = s.permission?.detail, !d.isEmpty {
                Text(d).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            }
            ReplyButton(title: "Answer in \(store.caps(s).app) ↗", color: accent) { store.jump(s) }
                .tip("Spyglass can't press keys in \(store.caps(s).app); this jumps there")
        }
        .padding(.top, 2)
    }
}

/// Claude's question, kept small: the question and one chip per option. Complex questions point to the terminal.
struct QuestionCard: View {
    let s: Session
    let q: Question
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(q.text).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).tip(q.text)
            if let a = store.answers[s.id] {
                Text(a.failed.map { "⚠︎ \($0)" } ?? "Answering: \(a.name)…").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(a.failed == nil ? .white.opacity(0.6) : .orange)
            } else if let opts = q.options, !opts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(opts.enumerated()), id: \.offset) { i, label in
                        ReplyButton(title: label, color: i == 0 ? accent : .white.opacity(0.8)) { store.answer(s, i) }
                            .lineLimit(1).tip("Answer \"\(label)\" (same as pressing \(i + 1))")
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Several questions or choices: answer in the terminal ↗").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.top, 2)
    }
}

struct ReplyButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(color)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.16 : 0.09)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// "Switch to Sonnet?" asked in the panel, so the terminal's own confirmation needs no visit.
struct ModelConfirm: View {
    let s: Session
    let alias: String
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switch to \(alias.capitalized)?").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            Text("The next reply re-reads the whole conversation, so it's slower and uses more tokens.")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ReplyButton(title: "Switch", color: accent) { store.switchModel(s, to: alias) }
                ReplyButton(title: "Cancel", color: .white.opacity(0.75)) { store.confirming[s.id] = nil }
                Spacer()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
        .padding(.top, 2)
    }
}

struct ModelPicker: View {
    let s: Session
    @ObservedObject var store: Store
    var canSwitch: Bool { (s.state == "idle" || s.state == "done") && store.caps(s).typeText }
    var pending: ModelSwitch? { store.switching[s.id] }
    let cyan = Color(red: 0.45, green: 0.80, blue: 0.90)

    var body: some View {
        if let p = pending, let why = p.failed {
            Text("⚠︎ \(p.alias.capitalized)").foregroundColor(.orange).tip(why)
        } else if let p = pending {
            Text("→ \(p.alias.capitalized)…").foregroundColor(cyan.opacity(0.7)).tip("Switching model")
        } else {
            if Store.snapshotMode {
                Text(s.model.map { "\($0) ▾" } ?? "Model ▾").foregroundColor(s.model == nil ? .white.opacity(0.4) : cyan)
            } else {
            Menu {
                ForEach(ModelSwitch.aliases, id: \.self) { a in
                    Button { store.confirming[s.id] = a } label: {
                        if (s.model ?? "").lowercased().contains(a) { Label(a.capitalized, systemImage: "checkmark") }
                        else { Text(a.capitalized) }
                    }
                }
            } label: {
                Text(s.model.map { "\($0) ▾" } ?? "Model ▾")
                    .foregroundColor(s.model == nil ? .white.opacity(0.4) : cyan)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!canSwitch)
            .tip(canSwitch ? "Switch this session's model"
                 : !store.caps(s).typeText ? "Spyglass can't type into \(store.caps(s).app): jump there and use /model"
                 : "Model can be switched once the session is idle")
            }
        }
    }
}

/// ⚙ in the header: sounds, coming back, views, start at login, welcome.
struct SettingsMenu: View {
    @ObservedObject var store: Store
    var body: some View {
        if Store.snapshotMode {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                .foregroundColor(.white.opacity(0.75))
        } else {
            Menu {
                Section("Sounds") {
                    Toggle("Chime when a session finishes", isOn: Binding(get: { store.soundDone }, set: { store.setPref("soundDone", $0) }))
                    Toggle("Ping when a session needs you", isOn: Binding(get: { store.soundNeeds }, set: { store.setPref("soundNeeds", $0) }))
                }
                Section("Panel") {
                    Toggle("Come back when a session needs you", isOn: Binding(get: { store.autoShow }, set: { store.setPref("autoShow", $0) }))
                    Toggle("Compact view", isOn: Binding(get: { store.compact }, set: { _ in store.toggleCompact() }))
                    Toggle("Start at login", isOn: Binding(get: { store.startsAtLogin }, set: { store.setStartAtLogin($0) }))
                }
                Button("Show welcome") { store.reopenWelcome() }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.75))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22, height: 22)
            .tip("Settings")
        }
    }
}

/// First run: what Spyglass is, and a setup checklist that ticks itself off.
struct WelcomeCard: View {
    @ObservedObject var store: Store
    @State private var setup = Store.SetupState(stats: false, editors: [], editorExtension: false)
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    func item(_ done: Bool, _ title: String, _ hint: String, note: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note ? "info.circle" : done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(done ? accent : .white.opacity(note ? 0.6 : 0.45))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(done ? 0.6 : 0.92))
                if !done { Text(hint).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Welcome to Spyglass").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Text("One row for every Claude Code session on this Mac: what it's doing, what needs you, and how much of your plan you've used. Answer prompts right here. Everything stays on your Mac.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            item(setup.stats, "Model, context and plan usage", "Run /spyglass:setup in any Claude session.")
            if !setup.editors.isEmpty {
                item(setup.editorExtension, "\(setup.editors.joined(separator: " / ")): jump to and type into tabs",
                     "Run /spyglass:editor, then reload the editor window once.")
            }
            item(false, "macOS will ask once to let Spyglass control your terminal",
                 "When you first jump to or answer a session in iTerm2 or Terminal. Choose Allow.", note: true)
            HStack {
                Spacer()
                ReplyButton(title: "Got it", color: accent) { store.dismissWelcome() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.35), lineWidth: 1))
        .onAppear { setup = store.setupState() }
        .onReceive(timer) { _ in setup = store.setupState() }
    }
}

/// Plan limits left before they renew, e.g. "5h 83% left · 19:00   Week 93% left · Tue 10:30".
struct UsageLine: View {
    let limits: [LimitWindow]
    func windowText(_ w: LimitWindow) -> String {
        let renews = w.resets.map { " · \(resetTime($0))" } ?? ""
        if w.key == "spend_limit", let u = w.usd {
            return String(format: "Spend $%.2f", u) + (w.limitUsd.map { String(format: " of $%.0f", $0) } ?? "") + renews
        }
        return "\(w.label) \(w.left)% left" + renews
    }
    func color(_ w: LimitWindow) -> Color { w.pct >= 90 ? .red : w.pct >= 70 ? .orange : .white.opacity(0.6) }
    var body: some View {
        let main = limits.filter { $0.isPlanWindow || $0.key == "spend_limit" }
        let over = limits.filter { $0.isPlanWindow && $0.pct >= 100 }
        VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 14) {
            ForEach(main.isEmpty ? Array(limits.prefix(2)) : main, id: \.key) { w in
                HStack(spacing: 5) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(color(w)).frame(width: g.size.width * CGFloat(min(max(w.pct / 100, 0), 1)))
                        }
                    }.frame(width: 26, height: 4)
                    Text(windowText(w)).foregroundColor(color(w)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        if !over.isEmpty {
            Text("Past your \(over.map { $0.label == "5h" ? "5-hour" : "weekly" }.joined(separator: " and ")) limit: extra usage is billed at API prices if it's on")
                .foregroundColor(.red).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        }
        .font(.system(size: 11, weight: .medium))
        .tip(limits.map { "\($0.label): \(Int($0.pct.rounded()))% used, \($0.left)% left" + ($0.resets.map { ", renews \(resetTime($0))" } ?? "") }
              .joined(separator: "\n"))
    }
}

/// One line per session: status dot, name, model, context, usage; hover for the activity, double-click to jump.
struct CompactRow: View {
    let s: Session
    @ObservedObject var store: Store
    var why = false   // collapsed list: say why the row is shown (Needs you / Done · 2m) instead of model and context
    @State private var hover = false
    var dot: Color {
        switch s.state {
        case "working": return accent
        case "done": return accent.opacity(0.45)
        case "waiting": return .orange
        default: return .gray.opacity(0.6)
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
                .overlay(Circle().stroke(colorFor(s.id).opacity(0.8), lineWidth: 1.5).frame(width: 11, height: 11))
            Text(s.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                .lineLimit(1).truncationMode(.tail).layoutPriority(0)
            Spacer(minLength: 4)
            if why {
                Group {
                    if s.state == "waiting" { Text("Needs you").foregroundColor(.orange) }
                    else {
                        let secs = Date().timeIntervalSince1970 - (store.justDone[s.id] ?? Date().timeIntervalSince1970)
                        Text(secs < 60 ? "Done · just now" : "Done · \(Store.ago(store.justDone[s.id]) ?? "")").foregroundColor(accent)
                    }
                }
                .font(.system(size: 10.5, weight: .semibold)).fixedSize()
            } else {
            Group {
                if let m = s.model { Text(m.components(separatedBy: " ").first ?? m).foregroundColor(Color(red: 0.45, green: 0.80, blue: 0.90)) }
                if let c = s.ctx { Text("\(c)%").foregroundColor(c >= 60 ? .yellow : .green).tip(store.contextHelp(s) ?? "") }
                if let u = store.usageLabel(s) { Text(u).foregroundColor(.white.opacity(0.45)).tip(store.usageHelp(s)) }
            }
            .font(.system(size: 10.5, weight: .semibold)).fixedSize().layoutPriority(1)
            }
            if hover {
                IconButton(symbol: "arrow.up.forward.square", help: "Jump to \(store.terminalLabel(s))") { store.jump(s) }
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.08 : 0.035)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {   // a click anywhere outside the row's buttons goes there (not while typing in it)
            if store.editing != s.id && store.replying != s.id { store.jump(s) }
        }
        .tip(store.rowHelp(s))
    }
}

struct EndedRow: View {
    let s: Session
    @ObservedObject var store: Store
    @State private var hover = false
    var ago: String {
        let m = Int((Date().timeIntervalSince1970 - (s.ended ?? 0)) / 60)
        return m < 1 ? "just now" : m < 60 ? "\(m)m ago" : "\(m / 60)h ago"
    }
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4).fill(colorFor(s.id).opacity(0.5)).frame(width: 6, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85)).lineLimit(1)
                HStack(spacing: 6) {
                    Text((s.cwd as NSString?)?.lastPathComponent ?? "")
                    Text("ended \(ago)")
                    if let m = s.model { Text(m) }
                    if let u = store.usageLabel(s) { Text(u) }
                }.font(.system(size: 10.5)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let r = store.resuming[s.id] {
                if let why = r.failed {
                    Text("⚠︎").foregroundColor(.orange).tip(why)
                } else {
                    Text("Opening…").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }
            } else {
                ReplyButton(title: "Resume", color: accent) { store.resume(s) }
                    .tip("Open a new terminal tab in \(s.cwd ?? "its folder") and run claude --resume")
            }
            IconButton(symbol: "xmark", help: "Remove from this list") { store.dismissEnded(s) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.07 : 0.035)))
        .onHover { hover = $0 }
        .tip(store.rowHelp(s))
    }
}

struct ProgressBar: View {
    let fraction: Double?
    let active: Bool
    let color: Color
    @State private var phase: CGFloat = -0.3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let f = fraction {
                    Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max(f, 0), 1)))
                } else if active {
                    Capsule().fill(color.opacity(0.85)).frame(width: g.size.width * 0.3)
                        .offset(x: g.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { phase = 0.7 }
                        }
                }
            }.clipShape(Capsule())
        }.frame(height: 4).padding(.top, 2)
    }
}

struct SpyglassView: View {
    @ObservedObject var store: Store
    var counts: String {
        let w = store.sessions.filter { $0.state == "working" }.count
        let n = store.sessions.filter { $0.state == "waiting" }.count
        let d = store.sessions.filter { $0.state == "done" }.count
        let f = store.sessions.filter { $0.contextFull }.count
        return [w > 0 ? "\(w) working" : nil, n > 0 ? "\(n) need you" : nil, d > 0 ? "\(d) done" : nil,
                f > 0 ? "\(f) context near full" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(store.sessions.contains { $0.state == "waiting" } ? Color.orange : accent)
                    .frame(width: 8, height: 8)
                Text("Spyglass").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text("\(store.sessions.count)").font(.system(size: 15, weight: .bold)).foregroundColor(.white.opacity(0.4))
                if store.collapsed && !counts.isEmpty {
                    Text(counts).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                SettingsMenu(store: store)
                IconButton(symbol: store.compact ? "rectangle.grid.1x2" : "list.bullet",
                           help: store.compact ? "Full rows" : "Compact view") { store.toggleCompact() }
                IconButton(symbol: store.muted ? "speaker.slash" : "speaker.wave.2",
                           help: store.muted ? "Unmute sounds" : "Mute sounds") { store.toggleMute() }
                IconButton(symbol: store.collapsed ? "chevron.down" : "chevron.up",
                           help: store.collapsed ? "Expand" : "Collapse") { store.toggleCollapse() }
                IconButton(symbol: "xmark", help: "Hide Spyglass (bring it back from the menu bar)") { store.hidePanel() }
            }
            if store.showWelcome && !store.collapsed { WelcomeCard(store: store) }
            if !store.limits.isEmpty { UsageLine(limits: store.limits) }
            if store.collapsed && !store.peek.isEmpty {
                // Collapsed: still show which session just rang or needs you; click to jump (and clear it).
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.peek) { CompactRow(s: $0, store: store, why: true) }
                }
            }
            if !store.collapsed {
                if store.sessions.isEmpty {
                    Text("No recent Claude sessions").font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5)).padding(.vertical, 10).frame(maxWidth: .infinity)
                } else {
                    if store.compact {
                        let layout = store.compactLayout()
                        ForEach(layout.full) { Row(s: $0, store: store) }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(layout.groups, id: \.name) { g in
                                if !g.name.isEmpty {
                                    Text("\(g.name) · \(g.rows.count)").font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.4)).padding(.top, 4).padding(.leading, 4)
                                }
                                ForEach(g.rows) { CompactRow(s: $0, store: store) }
                            }
                        }
                    } else {
                        ForEach(store.sessions) { Row(s: $0, store: store) }
                    }
                }
                if !store.ended.isEmpty {
                    HStack(spacing: 6) {
                        Button { store.toggleEnded() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: store.showEnded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Recently ended · \(store.ended.count)").font(.system(size: 11, weight: .semibold))
                            }.foregroundColor(.white.opacity(0.55)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Spacer()
                        if store.showEnded {
                            Button("Clear") { store.clearEnded() }.buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                        }
                    }.padding(.top, 4)
                    if store.showEnded { ForEach(store.ended) { EndedRow(s: $0, store: store) } }
                }
                if store.olderIdle > 0 {
                    Text("+ \(store.olderIdle) older idle session\(store.olderIdle == 1 ? "" : "s") (no activity in 12h)")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}

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
            .onDisappear { TipCenter.shared.hover(id, "", false) }
    }
}

extension View {
    /// Hover card that works while Spyglass isn't the active app (replaces .help).
    func tip(_ text: String) -> some View { modifier(TipModifier(text: text)) }
}

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

    func applicationDidFinishLaunching(_ n: Notification) {
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

        // Keep the window sized to its content, anchored at the top edge.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
    }
}

// MARK: - Test modes (tests/run.sh): no window, no sounds. Use with SPYGLASS_HOME=<fixtures> SPYGLASS_NO_REGISTRY=1.

/// --selftest: print each row's computed state as JSON lines, then exit.
/// --snapshot <out.png>: render the panel from the same state to a PNG, then exit.
@MainActor func runTestMode() -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--selftest") || args.contains("--snapshot") else { return false }
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
            if ["soundDone", "soundNeeds", "autoShow"].contains(k) {
                switch k { case "soundDone": store.soundDone = v == "true"; case "soundNeeds": store.soundNeeds = v == "true"; default: store.autoShow = v == "true" }
            }
        }
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
        for s in store.sessions {
            var row: [String: Any] = ["id": s.id, "name": s.displayTitle, "state": s.state, "contextFull": s.contextFull,
                                      "canRename": store.canRename(s)]
            row["model"] = s.model; row["ctx"] = s.ctx; row["tabName"] = s.tabName
            row["permission"] = s.permission?.detail
            row["asked"] = s.asked?.text
            row["lastLine"] = s.lastLine; row["oldHooks"] = store.oldHooks(s)
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

// MARK: - Command line: hooks and a small JSON helper (no jq needed)
//
//   Spyglass hook record | stats | answer      (stdin: Claude Code hook / statusline JSON)
//   Spyglass json get|raw|eq|set|make|valid|tail-has|now ...   (for the plugin's shell scripts)
// Runs before any window code and exits.

enum JSON {
    static func load(_ path: String) -> Any? {
        let data: Data?
        if path == "-" { data = FileHandle.standardInput.readDataToEndOfFile() }
        else { data = FileManager.default.contents(atPath: path) }
        guard let d = data, !d.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
    static func parse(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
    static func text(_ v: Any, pretty: Bool = false) -> String {
        var o: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]
        if pretty { o.insert(.prettyPrinted) }
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: o) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }
    /// Atomic write (tmp + rename), pretty, so the files stay readable.
    @discardableResult static func save(_ v: Any, to path: String) -> Bool {
        let tmp = path + ".spyglass.tmp"
        guard let d = text(v, pretty: true).data(using: .utf8), FileManager.default.createFile(atPath: tmp, contents: d) else { return false }
        if rename(tmp, path) != 0 { unlink(tmp); return false }
        return true
    }
    /// ".a.b", ."quoted.key", ".list.0"
    static func segments(_ path: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, i = path.startIndex
        while i < path.endIndex {
            let c = path[i]
            if quoted { if c == "\"" { quoted = false } else { cur.append(c) } }
            else if c == "\"" { quoted = true }
            else if c == "." { if !cur.isEmpty { out.append(cur) }; cur = "" }
            else { cur.append(c) }
            i = path.index(after: i)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
    static func get(_ v: Any?, _ path: String) -> Any? {
        var cur = v
        for seg in segments(path) {
            if let d = cur as? [String: Any] { cur = d[seg] }
            else if let a = cur as? [Any], let n = Int(seg), n >= 0, n < a.count { cur = a[n] }
            else { return nil }
        }
        return cur is NSNull ? nil : cur
    }
    static func set(_ v: Any?, _ segs: ArraySlice<String>, _ value: Any?) -> Any? {
        guard let first = segs.first else { return value }
        var d = (v as? [String: Any]) ?? [:]
        if segs.count == 1 { if let value { d[first] = value } else { d.removeValue(forKey: first) } }
        else { d[first] = set(d[first], segs.dropFirst(), value) }
        return d
    }
    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil || b == nil || a is NSNull || b is NSNull { return (a == nil || a is NSNull) && (b == nil || b is NSNull) }
        if let x = a as? NSNumber, let y = b as? NSNumber, !isBool(x), !isBool(y) { return x.doubleValue == y.doubleValue }
        return text(a!) == text(b!)
    }
    /// Raw value for the shell: strings unquoted, numbers plain (integers without ".0"), others as JSON.
    static func raw(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, !isBool(n) {
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)"
        }
        return text(v)
    }
    /// A command-line value: JSON if it parses, else the string itself.
    static func value(_ s: String) -> Any { parse(s) ?? s }
}

enum CLI {
    static var home: String {
        ProcessInfo.processInfo.environment["SPYGLASS_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.claude/spyglass")
    }
    static var now: Int { Int(Date().timeIntervalSince1970) }
    static func env(_ k: String) -> String { ProcessInfo.processInfo.environment[k] ?? "" }

    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { return 2 }
        switch (args[0], args[1]) {
        case ("hook", "record"): return hookRecord()
        case ("hook", "stats"): return hookStats()
        case ("hook", "answer"): return hookAnswer()
        case ("json", _): return json(Array(args.dropFirst()))
        default: return 2
        }
    }

    // MARK: json helper

    static func json(_ a: [String]) -> Int32 {
        let cmd = a[0]
        switch cmd {
        case "now":   // epoch seconds with milliseconds, for request ids
            print(String(format: "%.3f", Date().timeIntervalSince1970)); return 0
        case "get", "raw":   // get FILE PATH -> raw value (empty if missing); raw -> compact JSON (null if missing)
            guard a.count >= 3 else { return 2 }
            let v = JSON.get(JSON.load(a[1]), a[2])
            if cmd == "raw" { print(v.map { JSON.text($0) } ?? "null"); return 0 }
            if let v { print(JSON.raw(v)) }
            return v == nil ? 1 : 0
        case "eq":   // eq FILE PATH JSONVALUE -> exit 0 if equal
            guard a.count >= 4 else { return 2 }
            return JSON.equal(JSON.get(JSON.load(a[1]), a[2]), JSON.value(a[3])) ? 0 : 1
        case "valid":
            guard a.count >= 2, let d = FileManager.default.contents(atPath: a[1]),
                  (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil else { return 1 }
            return 0
        case "make":   // make --str K V | --json K J ...  -> object on stdout
            var o: [String: Any] = [:], i = 1
            while i + 2 < a.count {
                let flag = a[i], k = a[i + 1], v = a[i + 2]
                o[k] = flag == "--str" ? v : JSON.value(v)
                i += 3
            }
            print(JSON.text(o)); return 0
        case "set":   // set FILE [--if P J]... (--str P V | --json P J | --del P)...  exit 3 if a condition fails
            guard a.count >= 2 else { return 2 }
            let file = a[1]
            // Never overwrite a file that exists but isn't plain JSON (e.g. settings with comments): refuse.
            if let d = FileManager.default.contents(atPath: file), !d.isEmpty, JSON.load(file) == nil { return 1 }
            var doc: Any? = JSON.load(file) ?? [String: Any]()
            var i = 2
            var changes: [(String, Any?)] = []
            while i < a.count {
                switch a[i] {
                case "--if":
                    guard i + 2 < a.count else { return 2 }
                    if !JSON.equal(JSON.get(doc, a[i + 1]), JSON.value(a[i + 2])) { return 3 }
                    i += 3
                case "--str": guard i + 2 < a.count else { return 2 }; changes.append((a[i + 1], a[i + 2])); i += 3
                case "--json": guard i + 2 < a.count else { return 2 }; changes.append((a[i + 1], JSON.value(a[i + 2]))); i += 3
                case "--del": guard i + 1 < a.count else { return 2 }; changes.append((a[i + 1], nil)); i += 2
                default: return 2
                }
            }
            for (p, v) in changes { doc = JSON.set(doc, ArraySlice(JSON.segments(p)), v) }
            return JSON.save(doc ?? [String: Any](), to: file) ? 0 : 1
        case "tail-has":   // tail-has FILE FROMLINE PATH JSONVALUE -> a line after FROMLINE has PATH == VALUE
            guard a.count >= 5, let from = Int(a[2]), let data = FileManager.default.contents(atPath: a[1]) else { return 1 }
            let want = JSON.value(a[4])
            var n = 0
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
                n += 1
                guard n > from, !line.isEmpty, let o = try? JSONSerialization.jsonObject(with: line) else { continue }
                if JSON.equal(JSON.get(o, a[3]), want) { return 0 }
            }
            return 1
        default: return 2
        }
    }

    // MARK: hooks

    static func readStdin() -> [String: Any]? { JSON.load("-") as? [String: Any] }

    static func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
    static func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }

    /// Fingerprint of a tool call: hook answers are accepted only for the prompt with this key.
    static func fingerprint(_ input: Any?) -> String {
        let canon = JSON.text(input ?? [String: Any]())
        return SHA256.hash(data: Data(canon.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Walks up from this process to the claude process: its pid and the first real tty on the way.
    static func claudeProcess() -> (pid: Int?, tty: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        var parent: [Int: Int] = [:], tty: [Int: String] = [:], comm: [Int: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count >= 4, let pid = Int(f[0]), let pp = Int(f[1]) else { continue }
            parent[pid] = pp; tty[pid] = String(f[2]); comm[pid] = String(f[3])
        }
        var cur = Int(getpid()), foundTTY: String? = nil
        for _ in 0..<64 {
            guard cur > 1 else { break }
            if foundTTY == nil, let t = tty[cur], t != "??" { foundTTY = "/dev/" + t }
            if let c = comm[cur], c.contains("claude") { return (cur, foundTTY) }
            guard let pp = parent[cur] else { break }
            cur = pp
        }
        return (nil, foundTTY)
    }

    /// Last line of a (possibly huge) transcript containing `needle`, via grep.
    static func lastLine(_ file: String, _ needle: String) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-h", "-F", needle, file]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let last = data.split(separator: 0x0A).last else { return nil }
        return (try? JSONSerialization.jsonObject(with: last)) as? [String: Any]
    }

    /// The last line of a reply, for the row preview (markdown marks removed).
    static func lastLine(_ message: String?) -> String? {
        guard let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
        let lines = m.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.hasPrefix("```") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard var last = lines.last else { return nil }
        last = last.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        for p in ["- ", "* ", "> "] where last.hasPrefix(p) { last.removeFirst(2) }
        return last.isEmpty ? nil : cut(last, 160)
    }

    /// The question a reply ends with, if its last line asks one ("…, shall I go ahead?"). Code blocks don't count.
    static func endingQuestion(_ message: String?) -> String? {
        guard let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty, !m.hasSuffix("```") else { return nil }
        guard var last = m.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) else { return nil }
        last = last.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        if last.hasPrefix("- ") || last.hasPrefix("* ") { last.removeFirst(2) }
        guard last.hasSuffix("?") else { return nil }
        // A long last line: keep its last sentence or two, which is the question.
        if last.count > 200, let r = last.range(of: #"[^.!?]*\?$"#, options: .regularExpression) {
            last = String(last[r]).trimmingCharacters(in: .whitespaces)
        }
        return cut(last, 200)
    }

    static func activity(_ tool: String, _ i: [String: Any]) -> String {
        func str(_ k: String) -> String? { i[k] as? String }
        let base = ((str("file_path") ?? str("notebook_path") ?? "") as NSString).lastPathComponent
        let t: String
        switch tool {
        case "Bash": t = str("description") ?? str("command") ?? "Running a command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": t = "Editing " + base
        case "Read": t = "Reading " + base
        case "Grep": t = "Searching for " + (str("pattern") ?? "")
        case "Glob": t = "Finding " + (str("pattern") ?? "files")
        case "Agent", "Task": t = "Subagent: " + (str("description") ?? "working")
        case "WebFetch":
            var u = str("url") ?? ""
            if let r = u.range(of: #"^https?://"#, options: .regularExpression) { u.removeSubrange(r) }
            t = "Reading " + u
        case "WebSearch": t = "Searching the web: " + (str("query") ?? "")
        case "AskUserQuestion": t = "Asking you a question"
        case "Skill": t = "Using skill " + (str("skill") ?? "")
        default:
            if tool.hasPrefix("mcp__") {
                let p = tool.components(separatedBy: "__")
                var server = p.count > 1 ? p[1] : ""
                if server.hasPrefix("claude_ai_") { server.removeFirst("claude_ai_".count) }
                t = server + " · " + (p.count > 2 ? p[2] : "")
            } else { t = tool }
        }
        return cut(oneLine(t), 80)
    }

    static func question(_ input: [String: Any], now: Int) -> [String: Any] {
        let qs = input["questions"] as? [[String: Any]] ?? []
        let q = qs.first ?? [:]
        let opts = q["options"] as? [[String: Any]] ?? []
        let simple = qs.count == 1 && !((q["multiSelect"] as? Bool) ?? false) && opts.count <= 4
        var out: [String: Any] = [
            "text": cut(oneLine(q["question"] as? String ?? "Claude has a question"), 200),
            "at": now,
            "options": simple ? opts.map { cut(($0["label"] as? String) ?? "", 40) } : [String](),
        ]
        out["header"] = q["header"] ?? NSNull()
        return out
    }

    /// record: hook event -> sessions/<id>.json (same rules as the old record.sh).
    static func hookRecord() -> Int32 {
        guard let input = readStdin(), let sid = input["session_id"] as? String, !sid.isEmpty else { return 0 }
        let dir = home + "/sessions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = "\(dir)/\(sid).json"
        let ev = input["hook_event_name"] as? String ?? ""
        let now = CLI.now
        let old = (JSON.load(f) as? [String: Any]) ?? [:]

        if ev == "SessionEnd" {
            // Ended sessions go to ended/ for Resume (only ones that got a prompt).
            if let p = old["prompt"] as? String, !p.isEmpty {
                try? FileManager.default.createDirectory(atPath: home + "/ended", withIntermediateDirectories: true)
                var e = old; e["ended"] = now; e.removeValue(forKey: "permission")
                JSON.save(e, to: "\(home)/ended/\(sid).json")
            }
            unlink(f); return 0
        }

        var o = old
        o["id"] = sid
        o["cwd"] = (input["cwd"] as? String) ?? (old["cwd"] as? String) ?? ""
        o["updated"] = now
        if o["started"] == nil { o["started"] = now }
        if o["steps"] == nil { o["steps"] = 0 }

        // Where it lives (once per session, refreshed on each prompt).
        if old.isEmpty || ev == "SessionStart" || ev == "UserPromptSubmit" {
            let (pid, tty) = claudeProcess()
            if let pid { o["pid"] = pid }
            if let tty { o["tty"] = tty }
        }
        // Title: /rename name, else Claude's auto title (on prompt, stop, start, or while there is none).
        if ev == "UserPromptSubmit" || ev == "Stop" || ev == "SessionStart" || ((old["title"] as? String) ?? "").isEmpty,
           let tp = input["transcript_path"] as? String, FileManager.default.fileExists(atPath: tp) {
            if let t = lastLine(tp, "\"customTitle\"")?["customTitle"] as? String, !t.isEmpty {
                o["title"] = t; o["titleSource"] = "custom"
            } else if let t = lastLine(tp, "\"type\":\"ai-title\"")?["aiTitle"] as? String, !t.isEmpty {
                o["title"] = t; o["titleSource"] = "ai"
            }
        }
        // Which Spyglass version these hooks are, so the panel can say when a restart would bring newer features.
        if let root = ProcessInfo.processInfo.environment["CLAUDE_PLUGIN_ROOT"],
           let v = JSON.get(JSON.load(root + "/.claude-plugin/plugin.json"), ".version") as? String { o["hooks"] = v }
        for (k, e) in [("term", "TERM_PROGRAM"), ("bundle", "__CFBundleIdentifier"), ("entrypoint", "CLAUDE_CODE_ENTRYPOINT")] {
            if !env(e).isEmpty { o[k] = env(e) }
        }
        if !env("CMUX_WORKSPACE_ID").isEmpty { o["cmuxWorkspace"] = env("CMUX_WORKSPACE_ID"); o["cmuxSurface"] = env("CMUX_SURFACE_ID") }

        let tool = input["tool_name"] as? String ?? ""
        let ti = input["tool_input"] as? [String: Any] ?? [:]
        if ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"].contains(ev) { o.removeValue(forKey: "permission") }
        if ev != "Notification" { o.removeValue(forKey: "asked") }   // any activity answers or supersedes it
        if ev == "UserPromptSubmit" { o.removeValue(forKey: "lastLine") }
        if ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"].contains(ev) || (ev == "PreToolUse" && tool != "AskUserQuestion") {
            o.removeValue(forKey: "question")
        }
        let steps = (o["steps"] as? Int) ?? 0
        switch ev {
        case "SessionStart":
            o["status"] = "idle"; o["activity"] = "Ready"
        case "PermissionRequest" where tool == "AskUserQuestion", "PreToolUse" where tool == "AskUserQuestion":
            // A question, not a permission prompt: "Allow once" (key 1) would silently pick the first option.
            o["status"] = "waiting"; o["activity"] = "Asking you a question"; o["question"] = question(ti, now: now)
            if ev == "PreToolUse" { o["steps"] = steps + 1 }
        case "PermissionRequest":
            o["status"] = "waiting"; o["activity"] = "Wants to use " + (tool.isEmpty ? "a tool" : tool)
            let detail = ["command", "file_path", "notebook_path", "url", "query", "pattern"].lazy.compactMap { ti[$0] as? String }.first ?? ""
            o["permission"] = ["tool": tool, "detail": cut(oneLine(detail), 300), "at": now, "key": fingerprint(input["tool_input"])]
        case "UserPromptSubmit":
            o["status"] = "working"; o["activity"] = "Thinking…"; o["turnStarted"] = now
            let prompt = cut(oneLine(input["prompt"] as? String ?? ""), 120)
            o["prompt"] = prompt
            if ((o["title"] as? String) ?? "").isEmpty { o["title"] = cut(prompt, 50); o["titleSource"] = "prompt" }
        case "PreToolUse":
            o["status"] = "working"; o["activity"] = activity(tool, ti); o["steps"] = steps + 1
        case "PostToolUse":
            if let todos = ti["todos"] as? [[String: Any]] {
                o["total"] = todos.count
                o["done"] = todos.filter { ($0["status"] as? String) == "completed" }.count
                if let cur = todos.first(where: { ($0["status"] as? String) == "in_progress" }),
                   let a = (cur["activeForm"] as? String) ?? (cur["content"] as? String) { o["activity"] = a }
            }
            if (o["status"] as? String) == "waiting" { o["status"] = "working" }
        case "Notification":
            let msg = input["message"] as? String ?? ""
            // Claude Code's one-minute idle reminder isn't a question.
            if (input["notification_type"] as? String) != "idle_prompt" && !msg.contains("waiting for your input") {
                o["status"] = "waiting"; o["activity"] = cut(msg.isEmpty ? "Needs your attention" : msg, 80)
            }
        case "Stop":
            o["status"] = "done"; o["activity"] = "Finished — ready for you"
            if let l = lastLine(input["last_assistant_message"] as? String) { o["lastLine"] = l }
            // A turn that ends by asking you something is waiting on you, even without a prompt or question tool.
            if let q = endingQuestion(input["last_assistant_message"] as? String) {
                o["status"] = "waiting"; o["activity"] = "Asked you: " + cut(q, 70); o["asked"] = ["text": q, "at": now]
            }
        default: break
        }
        JSON.save(o, to: f)
        return 0
    }

    /// stats: statusline JSON -> stats/<id>.json (model, context, cost, plan limits).
    static func hookStats() -> Int32 {
        guard let input = readStdin(), let sid = input["session_id"] as? String, !sid.isEmpty else { return 0 }
        let dir = home + "/stats"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = (JSON.get(input, ".model.display_name") ?? JSON.get(input, ".model.id")) ?? NSNull()
        let pct = (JSON.get(input, ".context_window.used_percentage") as? NSNumber).map { Int($0.doubleValue.rounded(.down)) as Any } ?? NSNull()
        var limits: Any = NSNull()
        if let rl = input["rate_limits"] as? [String: Any] {
            var l: [String: Any] = [:]
            for (k, v) in rl {
                guard let w = v as? [String: Any], let p = w["used_percentage"] else { continue }
                var e: [String: Any] = ["pct": p, "resets": w["resets_at"] ?? NSNull()]
                if let u = w["used_usd"], !(u is NSNull) { e["usd"] = u; e["limitUsd"] = w["limit_usd"] ?? NSNull() }
                l[k] = e
            }
            limits = l
        }
        let o: [String: Any] = [
            "model": model, "ctx": pct,
            "ctxTokens": JSON.get(input, ".context_window.total_input_tokens") ?? NSNull(),
            "ctxSize": JSON.get(input, ".context_window.context_window_size") ?? NSNull(),
            "cost": JSON.get(input, ".cost.total_cost_usd") ?? NSNull(),
            "limits": limits, "updated": now,
        ]
        JSON.save(o, to: "\(dir)/\(sid).json")
        return 0
    }

    /// answer: PermissionRequest hook that waits for the panel's Allow / Deny (see answer.sh for the rules).
    static func hookAnswer() -> Int32 {
        guard let input = readStdin(), let sid = input["session_id"] as? String, !sid.isEmpty else { return 0 }
        if (input["tool_name"] as? String) == "AskUserQuestion" { return 0 }   // questions are answered by key
        if env("SPYGLASS_ASSUME_PANEL") != "1" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", "^\(home)/Spyglass$"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return 0 }
            p.waitUntilExit()
            if p.terminationStatus != 0 { return 0 }   // panel not running: no waiting
        }
        let key = fingerprint(input["tool_input"])
        let answer = "\(home)/answers/\(sid).json", session = "\(home)/sessions/\(sid).json"
        try? FileManager.default.createDirectory(atPath: home + "/answers", withIntermediateDirectories: true)
        let poll = Double(env("SPYGLASS_ANSWER_POLL")) ?? 0.25
        var seen = false, waited = 0.0
        while true {
            if let a = JSON.load(answer) as? [String: Any], (a["key"] as? String) == key {
                unlink(answer)
                let allow = (a["behavior"] as? String) == "allow"
                guard allow || (a["behavior"] as? String) == "deny" else { return 0 }
                if var s = JSON.load(session) as? [String: Any], JSON.get(s, ".permission.key") as? String == key {
                    s.removeValue(forKey: "permission")
                    s["status"] = allow ? "working" : "idle"
                    s["activity"] = allow ? "Approved from Spyglass" : "Denied from Spyglass"
                    JSON.save(s, to: session)
                }
                let decision: [String: Any] = allow ? ["behavior": "allow"]
                    // interrupt: stop the turn and wait for you, the same as pressing Esc.
                    : ["behavior": "deny", "message": "Denied from Spyglass", "interrupt": true]
                print(JSON.text(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]), terminator: "")
                return 0
            }
            // Resolved elsewhere (answered in the terminal, auto-approved, a new prompt, session gone): stop waiting.
            let doc = JSON.load(session)
            if doc == nil { return 0 }
            if (JSON.get(doc, ".permission.key") as? String) == key { seen = true }
            else if seen || waited > 10 { return 0 }
            Thread.sleep(forTimeInterval: poll); waited += poll
        }
    }
}

if CommandLine.arguments.count > 1, ["hook", "json"].contains(CommandLine.arguments[1]) {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

if MainActor.assumeIsolated({ runTestMode() }) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
