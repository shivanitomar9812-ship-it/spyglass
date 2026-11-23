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
    var remote: Bool?            // connected to Remote Control (Claude Code's registry has a bridgeSessionId)
    var asked: Asked?            // the turn ended with a question for you (in plain text)
    var lastLine: String?        // last line of Claude's final reply (finished turns)
    var hooks: String?           // Spyglass version of the hooks this session runs
    var hooksMissing: Bool?      // started after this Spyglass was installed, yet no hook data: something is broken
    var hooksQuiet: Double?      // its hooks stopped reporting (last report at this time) while the conversation went on
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
    /// The row shows what the tab shows. A rename from Spyglass renames the tab too, so they stay the same.
    var displayTitle: String {
        if let n = tabName, !n.isEmpty { return n }
        if titleSource == "custom", let t = title, !t.isEmpty { return t }
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

    /// Risky from the hook (full command), or from the shown text (older hooks, or a rule added since).
    var riskReason: String? { risky ?? Risk.reason(tool: tool, command: detail ?? "") }
}

/// Commands that can't be approved from the panel: one click on a reflex shouldn't delete, force-push or deploy.
/// The panel shows no Allow for them, and the answer hook refuses an allow, so they're answered in the terminal.
enum Risk {
    static let rules: [(String, String)] = [
        // Your machine
        (#"(^|[\s;&|(`'"])sudo\s"#, "sudo"),
        (#"(^|[\s;&|(`'"])rm\s+(-\S+\s+)*(-[a-z]*r|--recursive)"#, "recursive delete"),
        (#"(^|[\s;&|(`'"])(mkfs\S*|dd\s+[^;&|]*of=)"#, "writes a disk"),
        (#"\b(chmod|chown)\s+-R\b"#, "recursive permission change"),
        (#"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "runs a downloaded script"),
        // Git and publishing
        (#"\bgit\s+push\b[^;&|]*(\s--force|\s-f\b|\s\+\S)"#, "force-push"),
        (#"\bgit\s+push\b"#, "pushes to a remote"),
        (#"\bgit\s+reset\s+[^;&|]*--hard"#, "git reset --hard"),
        (#"\bgit\s+clean\s+-\S*f"#, "git clean"),
        (#"\b((docker|podman)\s+push|(npm|yarn|pnpm|cargo)\s+publish|twine\s+upload|gh\s+release\s+create|gh\s+pr\s+merge)\b"#, "publishes or merges"),
        // Production
        (#"\b(ssh|scp|rsync|psql|mysql|mongo|mongosh|redis-cli|clickhouse-client)\b[^;&|]*(^|[^a-z0-9])(prod|production)([^a-z0-9]|$)"#, "touches production"),
        // Clusters and infrastructure
        (#"\bkubectl\s+([^\s;&|]+\s+)*?(delete|apply|create|replace|patch|scale|autoscale|drain|cordon|uncordon|taint|label|annotate|set|edit|expose|run|exec|cp|rollout\s+(restart|undo|pause|resume))\b"#, "changes a Kubernetes cluster"),
        (#"\bhelm\s+([^\s;&|]+\s+)*?(install|upgrade|uninstall|delete|rollback)\b"#, "Helm release change"),
        (#"\bargocd\s+app\s+(sync|delete|rollback|set|patch|terminate-op)\b"#, "Argo CD change"),
        (#"\bterraform\s+([^\s;&|]+\s+)*?(apply|destroy|import|taint)\b|\bterraform\s+state\s+(rm|mv|push)\b"#, "Terraform change"),
        (#"\baws\s+([^\s;&|]+\s+)*?(delete|terminate|remove|put|update|create|modify|stop|reboot|deregister|detach)-[\w-]+"#, "changes AWS resources"),
        (#"\bgcloud\s+([^\s;&|]+\s+)*?(delete|deploy|update|create|set-iam-policy|reset|stop)\b"#, "changes Google Cloud resources"),
        (#"\baz\s+([^\s;&|]+\s+)*?(delete|create|update|deploy)\b"#, "changes Azure resources"),
        (#"\b(hdfs\s+dfs|hadoop\s+fs)\s+-(rm|rmr|expunge|mv|chmod|chown)\b"#, "changes HDFS"),
        (#"\b(aws\s+s3\s+(rm|rb|mv)|gsutil\s+(-m\s+)?(rm|mv))\b"#, "cloud storage delete"),
        // Databases
        (#"\b(insert\s+into|update\s+[\w."]+\s+set|delete\s+from|merge\s+into|truncate\s+(table\s+)?[\w."]+|alter\s+(table|database|schema|user|role|index|view|sequence)|create\s+(or\s+replace\s+)?(table|database|schema|index|user|role|view|function|trigger|extension)|drop\s+(table|database|schema|index|user|role|view|function)|(grant|revoke)\s+(all|select|insert|update|delete|usage|create|execute|connect))\b"#, "changes a database (SQL)"),
        (#"\b(psql|mysql|sqlite3|mongosh|clickhouse-client)\b[^;&|]*(\s-f\s|\s--file[=\s]|<\s*\S+\.(sql|js))"#, "runs a SQL file"),
        (#"\b(alembic\s+(upgrade|downgrade|stamp)|rails\s+db:\S+|rake\s+db:\S+|prisma\s+(migrate\s+(deploy|reset|dev)|db\s+push)|flyway\s+(migrate|clean|repair)|liquibase\s+(update|rollback|drop)|knex\s+migrate|sequelize\s+db:\S+|manage\.py\s+(migrate|flush))\b"#, "database migration"),
        (#"\bredis-cli\b[^;&|]*\b(flushall|flushdb|del|unlink|set|hset|expire|config\s+set)\b"#, "changes Redis"),
        (#"\b(dropDatabase|dropCollection|deleteMany|deleteOne|updateMany|updateOne|insertMany|insertOne|replaceOne)\b"#, "changes MongoDB"),
        // APIs
        (#"\bcurl\b[^;&|]*(-X\s*|--request\s+)(POST|PUT|PATCH|DELETE)\b"#, "sends a write request"),
    ]
    static let compiled: [(NSRegularExpression, String)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.0, options: [.caseInsensitive])).map { ($0, r.1) }
    }
    /// `command` is the command for Bash, else what the tool acts on (file path, URL…): built-in rules are for
    /// commands only; your own rules (risky.txt) apply to both.
    static func reason(tool: String?, command: String) -> String? {
        guard !command.isEmpty else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        let mine = custom()
        if tool == "Bash" || tool == nil,
           let r = compiled.first(where: { !mine.off.contains($0.1.lowercased()) && $0.0.firstMatch(in: command, range: range) != nil }) { return r.1 }
        return mine.rules.first { $0.matches(command) }.map { $0.reason }
    }

    // MARK: Your own rules: ~/.claude/spyglass/risky.txt (⚙ → Risky commands…)

    struct Rule {
        let text: String, regex: NSRegularExpression?, reason: String
        func matches(_ s: String) -> Bool {
            if let r = regex { return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
            return s.range(of: text, options: .caseInsensitive) != nil
        }
    }
    static var file: String {
        (ProcessInfo.processInfo.environment["SPYGLASS_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (Store.userHome + "/.claude/spyglass")) + "/risky.txt"
    }
    /// One rule per line: plain text matches anywhere (any case); `re:` starts a regular expression;
    /// `  # reason` is shown on the card. Lines starting with # are comments. Bad patterns are skipped.
    /// Built-in rule names, as shown on the card ("pushes to a remote"); `!name` in risky.txt turns one off.
    static var names: [String] { var seen = Set<String>(); return rules.map(\.1).filter { seen.insert($0).inserted } }

    static func parse(_ text: String) -> (rules: [Rule], off: Set<String>) {
        var off = Set<String>()
        let rules: [Rule] = text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("!") {   // turn off a built-in rule by its name; unknown names do nothing
                let name = line.dropFirst().split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                if names.contains(where: { $0.lowercased() == name }) { off.insert(name) }
                return nil
            }
            var why: String?
            if let r = line.range(of: " #") {
                why = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                line = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { return nil }
            let reason = (why?.isEmpty == false) ? why! : "matches your rule “\(line)”"
            if line.hasPrefix("re:") {
                guard let re = try? NSRegularExpression(pattern: String(line.dropFirst(3)), options: [.caseInsensitive]) else { return nil }
                return Rule(text: line, regex: re, reason: reason)
            }
            return Rule(text: line, regex: nil, reason: reason)
        }
        return (rules, off)
    }
    private static var cache: (stamp: Date?, rules: [Rule], off: Set<String>) = (nil, [], [])
    private static let lock = NSLock()
    /// Re-read only when the file changes (the panel asks on every redraw).
    static func custom() -> (rules: [Rule], off: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        if stamp == nil { cache = (nil, [], []); return ([], []) }
        if stamp != cache.stamp { let p = parse((try? String(contentsOfFile: file, encoding: .utf8)) ?? ""); cache = (stamp, p.rules, p.off) }
        return (cache.rules, cache.off)
    }
    static var template: String { templateHead + names.map { "#   !\($0)\n" }.joined() }
    static let templateHead = """
    # Spyglass: your own risky commands. A prompt that matches one of these gets no Allow button in the panel:
    # you read it and answer it in the terminal. The built-in list (rm -r, sudo, force-push, kubectl / Helm /
    # Terraform / cloud changes, pushes, SQL and database changes, production hosts, curl | sh…) always applies too.
    #
    # One rule per line. Lines starting with # are ignored. Changes apply right away.
    #   prod                       plain text: matches anywhere in the command, any case
    #   re:git push .* (main|master)$   re: starts a regular expression
    #   prod   # touches production     text after " #" is shown on the card as the reason
    # Rules also match the file a tool edits or the URL it fetches, e.g. .env or secrets/
    #
    # Examples (remove the leading # to use one):
    # prod                       # touches production
    # --context production       # production cluster
    # .env                       # secrets file
    # re:git push .* (main|master)$   # pushes to the main branch
    #
    # Turn off a built-in rule with ! and its name, as the card shows it, e.g.
    #   !pushes to a remote        ordinary git push is one-click again (force-push stays flagged)
    # Built-in rules (remove the leading # to turn one off):

    """
    /// ⚙ → "Allow from the panel": off means every prompt offers only Go to the tab and Deny.
    /// A file, not a preference, so the permission hook (a separate program) honours it too.
    static var allowOffFile: String { (file as NSString).deletingLastPathComponent + "/panel-allow-off" }
    static var panelAllow: Bool { !FileManager.default.fileExists(atPath: allowOffFile) }
    static func setPanelAllow(_ on: Bool) {
        if on { try? FileManager.default.removeItem(atPath: allowOffFile) }
        else {
            try? FileManager.default.createDirectory(atPath: (allowOffFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: allowOffFile, contents: Data("Allow from the panel is off (⚙ in Spyglass).\n".utf8))
        }
    }

    /// Creates the file with instructions the first time, then returns its path.
    static func ensureFile() -> String {
        // A file holding only an older version of these instructions (no rules yet) gets the current ones.
        if let t = try? String(contentsOfFile: file, encoding: .utf8), !t.contains("Built-in rules (remove"),
           t.split(whereSeparator: \.isNewline).allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix("#") }) {
            try? template.write(toFile: file, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? template.write(toFile: file, atomically: true, encoding: .utf8)
        }
        return file
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
