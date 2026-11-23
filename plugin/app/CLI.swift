// Spyglass: Command line: the hooks (record, answer, stats), the JSON helper for the scripts, and the doctor.
import CryptoKit
import Foundation

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
            ?? (Store.userHome + "/.claude/spyglass")   // $HOME, like the shell scripts (NSHomeDirectory ignores it)
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
        case ("doctor", _): return doctor(Array(args.dropFirst()))
        case ("away", _): return away(Array(args.dropFirst()))
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

    // MARK: doctor

    /// /spyglass:doctor: checks every link from this session to the panel and says how to fix what's broken.
    /// Args: [plugin root] [--session SID]. Exit 0 = all good, 1 = something to fix.
    static func doctor(_ a: [String]) -> Int32 {
        let fm = FileManager.default
        var root = a.first(where: { !$0.hasPrefix("--") }) ?? ""
        if root.isEmpty { root = env("CLAUDE_PLUGIN_ROOT") }
        let pluginVersion = JSON.get(JSON.load(root + "/.claude-plugin/plugin.json"), ".version") as? String
        var problems = 0
        func ok(_ m: String) { print("✓ " + m) }
        func warn(_ m: String, _ fix: String) { problems += 1; print("⚠︎ " + m + "\n    → " + fix) }

        // 1. The panel
        let bin = home + "/Spyglass"
        let running: Bool = {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "^\(bin)$"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }; p.waitUntilExit(); return p.terminationStatus == 0
        }()
        let installed = (try? String(contentsOfFile: home + "/version", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fm.isExecutableFile(atPath: bin) { warn("The panel isn't installed in \(home)", "Start a new Claude session, or run /spyglass:open") }
        else if !running { warn("The panel isn't running", "Run /spyglass:open (or ⚙ → Start at login)") }
        else if let v = pluginVersion, let i = installed, v != i {
            warn("The running panel is \(i) but the plugin is \(v)", "Run /spyglass:open to update it")
        } else { ok("Panel running" + (installed.map { " (\($0))" } ?? "")) }

        // 2. This session's hooks
        var sid: String? = nil
        if let i = a.firstIndex(of: "--session"), i + 1 < a.count { sid = a[i + 1] }
        if a.contains("--which") {   // tests: print the claude process and session this was run from
            let w = walkToClaude()
            print("pid=\(w.pid.map(String.init) ?? "-") session=\(w.pid.flatMap { JSON.get(JSON.load(Store.userHome + "/.claude/sessions/\($0).json"), ".sessionId") as? String } ?? "-")")
            return 0
        }
        if sid == nil, let pid = walkToClaude().pid {
            let reg = Store.userHome + "/.claude/sessions/\(pid).json"
            sid = JSON.get(JSON.load(reg), ".sessionId") as? String
        }
        if let sid {
            let row = JSON.load("\(home)/sessions/\(sid).json") as? [String: Any]
            let regPid = ((try? fm.contentsOfDirectory(atPath: Store.userHome + "/.claude/sessions")) ?? [])
                .compactMap { JSON.load(Store.userHome + "/.claude/sessions/" + $0) as? [String: Any] }
                .first { ($0["sessionId"] as? String) == sid }.flatMap { ($0["pid"] as? NSNumber)?.intValue }
            if row == nil {
                warn("This session isn't reporting through Spyglass's hooks", "Restart it (claude --resume). If it still fails, check that the spyglass plugin is enabled (/plugin) and hooks aren't disabled")
            } else if let rp = regPid, let p = (row?["pid"] as? NSNumber)?.intValue, rp != p {
                warn("This session's row points at the wrong process (\(p), Claude is \(rp))", "Update Spyglass (0.20.4 fixed this) and restart the session")
            } else if let h = row?["hooks"] as? String, let v = pluginVersion, Store.older(h, than: v) {
                warn("This session runs Spyglass \(h) hooks; \(v) is installed", "Restart it (claude --resume) for the newest features")
            } else { ok("This session reports to Spyglass" + ((row?["hooks"] as? String).map { " (hooks \($0))" } ?? "")) }
        } else {
            print("· Couldn't tell which session this is (run /spyglass:doctor inside a Claude session)")
        }

        // 2b. Claude Code version vs the one Spyglass was verified against
        let tested = JSON.get(JSON.load(root + "/compat.json"), ".claudeCode") as? String
        let claudeVersion: String? = {
            guard let sid else { return nil }
            let reg = Store.userHome + "/.claude/sessions"
            return ((try? fm.contentsOfDirectory(atPath: reg)) ?? []).lazy
                .compactMap { JSON.load(reg + "/" + $0) as? [String: Any] }
                .first { ($0["sessionId"] as? String) == sid }.flatMap { $0["version"] as? String }
        }()
        if let t = tested, let r = claudeVersion {
            if Store.older(t, than: r) {
                print("· Claude Code \(r) is newer than the \(t) Spyglass was verified against: if an action (model switch, reply, Allow / Deny) fails, that's the likely cause; please open an issue")
            } else { ok("Claude Code \(r) (Spyglass verified against \(t))") }
        }

        // 2c. Actions that failed in the last day (from the panel's log)
        let dayAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        let failures = ((try? String(contentsOfFile: home + "/spyglass.log", encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains("action failed:") && String($0.prefix(20)) >= String(dayAgo.prefix(20)) }
        if failures.isEmpty { ok("No failed actions in the last day") }
        else {
            warn("\(failures.count) action\(failures.count == 1 ? "" : "s") failed in the last day, latest: \(failures.last!.split(separator: " ", maxSplits: 1).last ?? "")",
                 "Hover the ⚠︎ on the row for why; if it keeps happening after a Claude Code update, open an issue with ~/.claude/spyglass/spyglass.log")
        }

        // 3. Statusline (model, context, plan usage)
        if Store.setupState().stats { ok("Statusline feeds Spyglass (model, context, plan usage)") }
        else { warn("Spyglass gets no model, context or plan usage", "Run /spyglass:setup, then send any message") }

        // 4. Cursor / VS Code
        let st = Store.setupState()
        if !st.editors.isEmpty {
            if !st.editorExtension { warn("\(st.editors.joined(separator: " / ")): the Spyglass extension isn't installed", "Run /spyglass:editor, then Developer: Reload Window") }
            else {
                // Ask the editor core to publish tab names; a fresh file means it is running in an open window.
                let ts = Date().timeIntervalSince1970
                let req = JSON.text(["ts": ts, "shellPid": 0, "text": "list:terminals"])
                try? req.write(toFile: home + "/send-request.json", atomically: true, encoding: .utf8)
                var alive = false
                for _ in 0..<30 {
                    let files = (try? fm.contentsOfDirectory(atPath: home + "/terminals")) ?? []
                    alive = files.contains { f in (JSON.get(JSON.load(home + "/terminals/" + f), ".ts") as? NSNumber).map { $0.doubleValue >= ts - 1 } ?? false }
                    if alive { break }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if alive { ok("\(st.editors.joined(separator: " / ")) extension answering") }
                else { warn("\(st.editors.joined(separator: " / ")) extension isn't answering (or no editor window is open)", "Developer: Reload Window in your editor; if that doesn't help, run /spyglass:editor") }
            }
        }

        print(problems == 0 ? "\nAll good." : "\n\(problems) thing\(problems == 1 ? "" : "s") to fix.")
        return problems == 0 ? 0 : 1
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

    /// The session's claude process: from Claude Code's own registry (~/.claude/sessions/<pid>.json names each session's
    /// id), else by walking up the process tree. Escaped (0.17-0.20.3): the walk matched "claude" anywhere in a path, and
    /// the installed hook binary lives under ~/.claude, so it recorded its own pid; the panel then saw that process gone
    /// and deleted the session's row.
    static func claudeProcess(_ sid: String) -> (pid: Int?, tty: String?) {
        let reg = Store.userHome + "/.claude/sessions"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: reg)) ?? [] where f.hasSuffix(".json") {
            guard let o = JSON.load(reg + "/" + f) as? [String: Any], (o["sessionId"] as? String) == sid,
                  let pid = (o["pid"] as? NSNumber)?.intValue, kill(pid_t(pid), 0) == 0 else { continue }
            return (pid, tty(of: pid))
        }
        return walkToClaude()
    }

    static func tty(of pid: Int) -> String? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_tdev != -1,
              let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Fallback: walk up from this hook's parent to a process named exactly "claude" (or a claude/versions binary).
    static func walkToClaude() -> (pid: Int?, tty: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        var parent: [Int: Int] = [:], tty: [Int: String] = [:], comm: [Int: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            // Columns are padded ("  71131 69566 ttys029  claude"); the command may contain spaces. Split into words.
            let w = line.split(separator: " ", omittingEmptySubsequences: true)
            guard w.count >= 4, let pid = Int(w[0]), let pp = Int(w[1]) else { continue }
            parent[pid] = pp; tty[pid] = String(w[2]); comm[pid] = w[3...].joined(separator: " ")
        }
        var cur = Int(getppid()), foundTTY: String? = nil   // not this process: its own path may contain .claude
        for _ in 0..<64 {
            guard cur > 1 else { break }
            if foundTTY == nil, let t = tty[cur], t != "??" { foundTTY = "/dev/" + t }
            if let c = comm[cur], (c as NSString).lastPathComponent == "claude" || c.contains("/claude/versions/") { return (cur, foundTTY) }
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
            let (pid, tty) = claudeProcess(sid)
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
            var perm: [String: Any] = ["tool": tool, "detail": cut(oneLine(detail), 300), "at": now, "key": fingerprint(input["tool_input"])]
            if let why = Risk.reason(tool: tool, command: detail) { perm["risky"] = why }   // the full text, not the cut one
            o["permission"] = perm
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
                // Risky commands are approved in the terminal only, whatever wrote this file.
                let ti = input["tool_input"] as? [String: Any] ?? [:]
                let subject = ["command", "file_path", "notebook_path", "url", "query", "pattern"].lazy.compactMap { ti[$0] as? String }.first ?? ""
                if allow, !Risk.panelAllow || Risk.reason(tool: input["tool_name"] as? String, command: subject) != nil {
                    Thread.sleep(forTimeInterval: poll); waited += poll; continue
                }
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
