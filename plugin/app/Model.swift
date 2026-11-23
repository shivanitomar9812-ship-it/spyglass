// Spyglass: Data the panel works with: sessions, plan limits, token totals.
import Foundation

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
    var hooksMissing: Bool?      // started after this Spyglass was installed, yet no hook data: something is broken
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
    var risky: String? // why the command can't be approved from the panel (see Risk)

    /// Risky from the hook (full command), or from the shown text for prompts recorded by older hooks.
    var riskReason: String? { risky ?? Risk.reason(tool: tool, command: detail ?? "") }
}

/// Commands that can't be approved from the panel: one click on a reflex shouldn't delete, force-push or deploy.
/// The panel shows no Allow for them, and the answer hook refuses an allow, so they're answered in the terminal.
enum Risk {
    static let rules: [(String, String)] = [
        (#"(^|[\s;&|(`'"])sudo\s"#, "sudo"),
        (#"(^|[\s;&|(`'"])rm\s+(-\S+\s+)*(-[a-z]*r|--recursive)"#, "recursive delete"),
        (#"\b(hdfs\s+dfs|hadoop\s+fs)\s+-rm"#, "HDFS delete"),
        (#"\b(aws\s+s3\s+(rm|rb)|gsutil\s+(-m\s+)?rm)\b"#, "cloud storage delete"),
        (#"\bgit\s+push\b[^;&|]*(\s--force|\s-f\b|\s\+\S)"#, "force-push"),
        (#"\bgit\s+reset\s+[^;&|]*--hard"#, "git reset --hard"),
        (#"\bgit\s+clean\s+-\S*f"#, "git clean"),
        (#"\bkubectl\s+([^\s;&|]+\s+)*?(delete|apply|replace|patch|scale|drain|edit|cordon|rollout\s+restart)\b"#, "changes a Kubernetes cluster"),
        (#"\bhelm\s+([^\s;&|]+\s+)*?(install|upgrade|uninstall|delete|rollback)\b"#, "Helm release change"),
        (#"\bterraform\s+([^\s;&|]+\s+)*?(apply|destroy)\b"#, "Terraform apply/destroy"),
        (#"\b(drop\s+(table|database|schema)|truncate\s+table|delete\s+from)\b"#, "destructive SQL"),
        (#"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "runs a downloaded script"),
        (#"(^|[\s;&|(`'"])(mkfs\S*|dd\s+[^;&|]*of=)"#, "writes a disk"),
        (#"\b(chmod|chown)\s+-R\b"#, "recursive permission change"),
    ]
    static let compiled: [(NSRegularExpression, String)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.0, options: [.caseInsensitive])).map { ($0, r.1) }
    }
    static func reason(tool: String?, command: String) -> String? {
        guard tool == "Bash" || tool == nil, !command.isEmpty else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        return compiled.first { $0.0.firstMatch(in: command, range: range) != nil }?.1
    }
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
