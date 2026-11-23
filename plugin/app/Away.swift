// Spyglass: Away mode. While you're away, what needs you goes to your phone (a Telegram bot chat) and Allow / Deny
// buttons there answer permission prompts through the same answer files the panel uses.
import AppKit
import Foundation

// MARK: - Config

/// ~/.claude/spyglass/away.json (mode 600): {"token": "...", "chat_id": "123", "finished": false, "auto": true, "idle_minutes": 10}.
/// Written by `Spyglass away setup`; the token never goes through a Claude session.
struct AwayConfig: Equatable {
    var token: String
    var chatId: String
    var finished = false      // also message when a session finishes (off by default: the noisy one)
    var auto = true           // switch on by itself when the screen locks or you're idle
    var idleMinutes = 10

    static var file: String { Store.home.path + "/away.json" }
    static func load() -> AwayConfig? {
        guard let o = JSON.load(file) as? [String: Any], let t = o["token"] as? String, !t.isEmpty else { return nil }
        let chat = (o["chat_id"] as? String) ?? (o["chat_id"] as? NSNumber).map { "\($0)" } ?? ""
        guard !chat.isEmpty else { return nil }
        var c = AwayConfig(token: t, chatId: chat)
        c.finished = (o["finished"] as? Bool) ?? false
        c.auto = (o["auto"] as? Bool) ?? true
        c.idleMinutes = max(1, (o["idle_minutes"] as? Int) ?? 10)
        return c
    }
    func save() {
        let o: [String: Any] = ["token": token, "chat_id": chatId, "finished": finished, "auto": auto, "idle_minutes": idleMinutes]
        try? FileManager.default.createDirectory(atPath: Store.home.path, withIntermediateDirectories: true)
        JSON.save(o, to: AwayConfig.file)
        chmod(AwayConfig.file, 0o600)
    }
}

// MARK: - Telegram

/// The few Bot API calls Spyglass needs. `SPYGLASS_TELEGRAM_API` points tests at a stand-in server.
struct Telegram {
    let token: String
    var base: String { ProcessInfo.processInfo.environment["SPYGLASS_TELEGRAM_API"] ?? "https://api.telegram.org" }

    func call(_ method: String, _ body: [String: Any], timeout: Double = 15, done: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: "\(base)/bot\(token)/\(method)"), let data = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { done(nil) }; return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { d, _, _ in
            let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done((o?["ok"] as? Bool) == true ? o : nil) }
        }.resume()
    }

    /// Blocking version for the setup command.
    func callSync(_ method: String, _ body: [String: Any], timeout: Double = 40) -> [String: Any]? {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        guard let url = URL(string: "\(base)/bot\(token)/\(method)"), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let o = d.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }), (o["ok"] as? Bool) == true { out = o }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
}

// MARK: - Bridge

/// Sends what needs you while away mode is on, takes the phone's Allow / Deny, and tidies the messages afterwards.
/// Safety lives in three places: only the configured chat is believed; a button works only for the prompt it was sent
/// for (fingerprint) and only if that prompt isn't risky and Allow from the panel is on; and the permission hook
/// re-checks risk and the lock before honouring any answer file.
final class AwayBridge {
    unowned let store: Store
    private(set) var config: AwayConfig?
    private var tg: Telegram?

    struct Item { var messageId: Int?; var head: String; var open: Bool }
    private var items: [String: Item] = [:]     // "p:<sid>:<at>" permission, "q:" question, "a:" asked, "d:" done
    private var polling = false
    private var offset = 0
    /// A button older than this is refused even if the prompt is still pending.
    static let expiry: Double = 3600
    private var pollTimeout: Int { Int(ProcessInfo.processInfo.environment["SPYGLASS_TELEGRAM_POLL"] ?? "") ?? 25 }
    private var pollGap: Double { pollTimeout == 0 ? 0.2 : 0 }

    init(store: Store) { self.store = store; reloadConfig() }

    func reloadConfig() {
        config = AwayConfig.load()
        tg = config.map { Telegram(token: $0.token) }
    }
    var configured: Bool { config != nil }

    // MARK: Sending

    private func cut(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
    private func folder(_ s: Session) -> String { ((s.cwd ?? "") as NSString).lastPathComponent }
    private func head(_ s: Session) -> String { folder(s).isEmpty ? s.displayTitle : "\(s.displayTitle) · \(folder(s))" }

    /// Called on every reload. Cheap when away mode is off and nothing is open.
    func sync(_ sessions: [Session]) {
        guard let cfg = config, let tg else { return }
        guard store.awayActive else {
            if items.values.contains(where: \.open) { closeAll(tg, "Away mode is off: answer it at your Mac") }
            polling = false
            return
        }
        for s in sessions {
            if s.state == "waiting" {
                if let p = s.permission, s.question == nil, p.tool != "AskUserQuestion" { sendPermission(tg, s, p) }
                else if let q = s.question { sendText(tg, "q:\(s.id):\(Int(q.at))", head(s), "❓ " + cut(q.text, 300) + optionsLine(q) + "\n\nAnswer it at your Mac.") }
                else if let a = s.asked { sendText(tg, "a:\(s.id):\(Int(a.at))", head(s), "💬 " + cut(a.text, 400) + "\n\nReply at your Mac.") }
            } else if cfg.finished, s.state == "done", let l = s.lastLine {
                sendText(tg, "d:\(s.id):\(Int(s.updated ?? 0))", head(s), "✅ Finished: " + cut(l, 200), open: false)
            }
        }
        resolveOpen(tg, sessions)
        startPolling()
    }

    private func optionsLine(_ q: Question) -> String { (q.options ?? []).isEmpty ? "" : "\n• " + (q.options ?? []).joined(separator: "\n• ") }

    private func sendText(_ tg: Telegram, _ id: String, _ head: String, _ body: String, open: Bool = true) {
        guard items[id] == nil, let cfg = config else { return }
        items[id] = Item(messageId: nil, head: head, open: open)
        tg.call("sendMessage", ["chat_id": cfg.chatId, "text": "\(head)\n\(body)"]) { [weak self] r in
            self?.items[id]?.messageId = ((r?["result"] as? [String: Any])?["message_id"] as? Int) ?? 0
        }
    }

    private func sendPermission(_ tg: Telegram, _ s: Session, _ p: Permission) {
        let id = "p:\(s.id):\(Int(p.at))"
        guard items[id] == nil, let cfg = config else { return }
        var text = "\(head(s))\n🟠 Wants to use \(p.tool ?? "a tool")"
        if let d = p.detail, !d.isEmpty { text += ":\n" + cut(d, 300) }
        var buttons: [[String: String]] = []
        let key = p.key ?? ""
        let tag = "\(s.id.prefix(8)):\(key)"
        if let why = p.riskReason {
            text += "\n\n⚠︎ Risky (\(why)): review it at your Mac. You can still deny it here."
        } else if !store.panelAllow {
            text += "\n\nAllow from the panel is off: answer it at your Mac, or deny it here."
        } else if !key.isEmpty {
            buttons.append(["text": "Allow once", "callback_data": "y:\(tag)"])
        }
        if !key.isEmpty { buttons.append(["text": "Deny", "callback_data": "n:\(tag)"]) }
        items[id] = Item(messageId: nil, head: text.components(separatedBy: "\n").first ?? "", open: true)
        var body: [String: Any] = ["chat_id": cfg.chatId, "text": text]
        if !buttons.isEmpty { body["reply_markup"] = ["inline_keyboard": [buttons]] }
        tg.call("sendMessage", body) { [weak self] r in
            self?.items[id]?.messageId = ((r?["result"] as? [String: Any])?["message_id"] as? Int) ?? 0
        }
    }

    // MARK: Tidying

    private func stillPending(_ id: String, _ sessions: [Session]) -> Bool {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let at = Int(parts[2]), let s = sessions.first(where: { $0.id == parts[1] }), s.state == "waiting" else { return false }
        switch parts[0] {
        case "p": return s.permission.map { Int($0.at) == at } ?? false
        case "q": return s.question.map { Int($0.at) == at } ?? false
        case "a": return s.asked.map { Int($0.at) == at } ?? false
        default: return false
        }
    }

    /// A prompt answered at the Mac (or gone) loses its buttons on the phone.
    private func resolveOpen(_ tg: Telegram, _ sessions: [Session]) {
        for (id, it) in items where it.open && it.messageId != nil && !stillPending(id, sessions) { close(tg, id, "✓ Handled at your Mac") }
    }

    private func closeAll(_ tg: Telegram, _ note: String) {
        for (id, it) in items where it.open && it.messageId != nil { close(tg, id, note) }
    }

    private func close(_ tg: Telegram, _ id: String, _ note: String, messageId: Int? = nil) {
        guard let it = items[id], let mid = messageId ?? it.messageId, mid != 0, let cfg = config else { items[id]?.open = false; return }
        items[id]?.open = false
        tg.call("editMessageText", ["chat_id": cfg.chatId, "message_id": mid, "text": "\(it.head)\n\(note)", "reply_markup": ["inline_keyboard": [[String]]()]]) { _ in }
    }

    // MARK: Receiving

    private func startPolling() {
        guard !polling, tg != nil else { return }
        polling = true
        poll()
    }

    private func poll() {
        guard polling, let tg, store.awayActive else { polling = false; return }
        tg.call("getUpdates", ["offset": offset, "timeout": pollTimeout, "allowed_updates": ["callback_query"]],
                timeout: Double(pollTimeout) + 15) { [weak self] r in
            guard let self else { return }
            for u in (r?["result"] as? [[String: Any]]) ?? [] {
                if let id = u["update_id"] as? Int { self.offset = max(self.offset, id + 1) }
                if let cb = u["callback_query"] as? [String: Any] { self.handle(cb) }
            }
            // A failed call backs off so a dead network doesn't spin.
            DispatchQueue.main.asyncAfter(deadline: .now() + (r == nil ? 5 : self.pollGap)) { self.poll() }
        }
    }

    private func toast(_ cb: [String: Any], _ text: String) {
        guard let tg, let id = cb["id"] as? String else { return }
        tg.call("answerCallbackQuery", ["callback_query_id": id, "text": text]) { _ in }
    }

    /// "y:<sid prefix>:<fingerprint>" or "n:…". Anything not from the configured chat is ignored without a reply.
    func handle(_ cb: [String: Any]) {
        guard let cfg = config else { return }
        let from = ((cb["from"] as? [String: Any])?["id"]).map { "\($0)" } ?? ""
        let chat = (((cb["message"] as? [String: Any])?["chat"] as? [String: Any])?["id"]).map { "\($0)" } ?? ""
        guard from == cfg.chatId, chat == cfg.chatId else { return }
        let parts = ((cb["data"] as? String) ?? "").split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "y" || parts[0] == "n" else { return }
        let approve = parts[0] == "y"
        guard store.awayActive else { toast(cb, "Away mode is off: answer it at your Mac"); return }
        guard let s = store.sessions.first(where: { $0.id.hasPrefix(parts[1]) }), s.state == "waiting",
              let p = s.permission, p.key == parts[2] else { toast(cb, "Already handled"); return }
        guard Date().timeIntervalSince1970 - p.at <= AwayBridge.expiry else { toast(cb, "Too old: answer it at your Mac"); return }
        if approve {
            if p.riskReason != nil { toast(cb, "Risky: review it at your Mac"); return }
            if !store.panelAllow { toast(cb, "Allow is off: answer it at your Mac"); return }
        }
        store.reply(s, approve: approve)
        toast(cb, approve ? "Allowed" : "Denied")
        // The message the button was on (always known), not our record of it, which may not be filled in yet.
        if let tg { close(tg, "p:\(s.id):\(Int(p.at))", approve ? "✅ Allowed from your phone" : "⛔️ Denied from your phone",
                          messageId: (cb["message"] as? [String: Any])?["message_id"] as? Int) }
    }
}

// MARK: - Deciding you're away

/// Turns away mode on by itself when the screen locks or you've been idle a while, and off when you're back.
/// Only if away.json asks for it ("auto": true). A manual switch (the header button) always wins and is never undone.
final class AwayWatch {
    private let store: Store
    private var locked = false
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        let c = DistributedNotificationCenter.default()
        c.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.check() }
        c.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 5
    }

    private var idle: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func check() {
        guard let cfg = store.awayBridge.config, cfg.auto else { if store.autoAway { store.autoAway = false }; return }
        let away = locked || idle >= Double(cfg.idleMinutes * 60)
        if away != store.autoAway { store.autoAway = away; store.reload() }
    }
}

// MARK: - Command line: Spyglass away setup | on | off | status

extension CLI {
    static func away(_ args: [String]) -> Int32 {
        let flag = Store.home.path + "/away-on"
        switch args.first ?? "status" {
        case "on", "off":
            try? FileManager.default.createDirectory(atPath: Store.home.path, withIntermediateDirectories: true)
            if args[0] == "on" {
                guard AwayConfig.load() != nil else { print("Away mode isn't set up yet. Run: Spyglass away setup"); return 1 }
                FileManager.default.createFile(atPath: flag, contents: Data("Away mode is on.\n".utf8))
            } else { try? FileManager.default.removeItem(atPath: flag) }
            print("Away mode \(args[0]).")
            return 0
        case "status":
            let cfg = AwayConfig.load()
            print(cfg == nil ? "Away mode: not set up (run: Spyglass away setup)"
                  : "Away mode: \(FileManager.default.fileExists(atPath: flag) ? "on" : "off") · phone chat set · auto \(cfg!.auto ? "on (idle \(cfg!.idleMinutes) min or screen lock)" : "off") · finished pings \(cfg!.finished ? "on" : "off")")
            return 0
        case "setup": return awaySetup()
        default:
            print("Usage: Spyglass away setup | on | off | status")
            return 2
        }
    }

    /// Reads the bot token from the terminal without echo (it must never pass through a Claude session), finds your
    /// chat by waiting for you to message the bot, saves away.json (mode 600) and sends a test message.
    static func awaySetup() -> Int32 {
        print("""
        Spyglass away mode sends what needs you to a private Telegram bot chat.
        1. In Telegram, message @BotFather: /newbot, pick a name, copy the token it gives you.
        2. Paste the token here (it is hidden, and stored only in \(AwayConfig.file), readable by you alone).
        """)
        print("Token: ", terminator: "")
        fflush(stdout)
        var old = termios(); tcgetattr(0, &old)
        var raw = old; raw.c_lflag &= ~tcflag_t(ECHO); tcsetattr(0, TCSANOW, &raw)
        let line = readLine() ?? ""
        tcsetattr(0, TCSANOW, &old); print("")
        let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let tg = Telegram(token: token)
        guard !token.isEmpty, let me = tg.callSync("getMe", [:]), let bot = (me["result"] as? [String: Any])?["username"] as? String else {
            print("Telegram didn't accept that token."); return 1
        }
        print("Connected to @\(bot). Open t.me/\(bot), press Start, and send it any message (waiting up to 2 minutes)…")
        var chat: String?, offset = 0
        let deadline = Date().addingTimeInterval(120)
        while chat == nil, Date() < deadline {
            let r = tg.callSync("getUpdates", ["offset": offset, "timeout": 10, "allowed_updates": ["message"]], timeout: 25)
            for u in (r?["result"] as? [[String: Any]]) ?? [] {
                if let id = u["update_id"] as? Int { offset = max(offset, id + 1) }
                if let m = u["message"] as? [String: Any], let c = m["chat"] as? [String: Any], (c["type"] as? String) == "private",
                   let id = c["id"] { chat = "\(id)" }
            }
        }
        guard let chat else { print("No message arrived. Run setup again and message the bot."); return 1 }
        let cfg = AwayConfig(token: token, chatId: chat)
        cfg.save()
        _ = tg.callSync("sendMessage", ["chat_id": chat, "text": "Spyglass is connected. In away mode, what needs you will be sent here, and only this chat can answer."])
        print("Done. A test message is on its way. Turn away mode on with the paper-plane button in the panel header, or: Spyglass away on")
        print("Only this chat can answer. Optional settings in \(AwayConfig.file): \"finished\": true (ping when a session finishes), \"auto\": false, \"idle_minutes\".")
        return 0
    }
}
