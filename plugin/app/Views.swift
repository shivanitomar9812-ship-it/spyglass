// Spyglass: The panel's SwiftUI views: header, rows, cards, menus.
import AppKit
import SwiftUI

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
    static let blinkClock = Timer.publish(every: 3.2, tolerance: 0.5, on: .main, in: .common).autoconnect()
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
        // One shared blink clock (each face used to start its own timer that never stopped); only working faces blink.
        .onReceive(Buddy.blinkClock) { _ in
            guard state == "working" else { return }
            withAnimation(.easeInOut(duration: 0.12)) { blink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.12)) { blink = false }
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
    var tint: Color = .white.opacity(0.75)
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(hover ? Color.white.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).foregroundColor(tint).tip(help)
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
                if s.hooksMissing == true {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold)).foregroundColor(.orange)
                        .tip("Hooks aren't reporting for this session, so Spyglass only sees its basic status. Run /spyglass:doctor in it.")
                } else if store.oldHooks(s) {
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
    var inPeek = false   // opened from the collapsed list: offers ⌃ to fold back
    @State private var hover = false

    var statusLine: (String, Color) {
        switch s.state {
        case "waiting":
            if let w = store.waitingFor(s), w >= 60 { return ("Needs you · \(Store.duration(w))", .orange) }
            return ("Needs you", .orange)
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
                if inPeek {
                    IconButton(symbol: "chevron.up", help: "Fold back to one line") { store.togglePeek(s) }
                } else {
                    IconButton(symbol: "xmark", help: "Hide until it does something new") { store.hide(s) }
                }
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
            if let why = perm.riskReason, reply == nil {
                Text("⚠︎ Risky: \(why)").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
            }
            HStack(spacing: 8) {
                if let r = reply, let why = r.failed {
                    Text("⚠︎ \(why)").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                } else if let r = reply {
                    Text(r.approve ? "Allowing…" : "Denying…").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                } else if let why = perm.riskReason {
                    ReplyButton(title: "Review in \(store.caps(s).app) ↗", color: .orange) { store.jump(s) }
                        .tip("Risky (\(why)): Spyglass doesn't approve these with one click. Read it and answer in \(store.caps(s).app). "
                             + (Risk.names.contains(why) ? "To stop flagging these, add “!\(why)” in ⚙ → Risky commands…" : "This is one of your rules in ⚙ → Risky commands…"))
                    ReplyButton(title: "Deny", color: .white.opacity(0.75)) { store.reply(s, approve: false) }
                        .tip("Decline it (same as pressing Esc)")
                } else if !store.panelAllow {
                    ReplyButton(title: "Go to \(store.caps(s).app) ↗", color: accent) { store.jump(s) }
                        .tip("Allow from the panel is off (⚙): answer it in \(store.caps(s).app)")
                    ReplyButton(title: "Deny", color: .white.opacity(0.75)) { store.reply(s, approve: false) }
                        .tip("Decline it (same as pressing Esc)")
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
/// Filters the list as you type (shown from Store.searchFrom sessions). Esc clears.
struct SearchField: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            if Store.snapshotMode {   // a TextField can't be drawn offscreen
                Text(store.query.isEmpty ? "Search sessions" : store.query).font(.system(size: 12))
                    .foregroundColor(.white.opacity(store.query.isEmpty ? 0.35 : 0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search sessions", text: $store.query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                    .focused($focused)
                    .onExitCommand { store.query = ""; focused = false }
            }
            if store.searching {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                }.buttonStyle(.plain).tip("Clear the search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
        .tip("Filter by tab name, folder, model or what it's doing. Several words narrow it down · Esc clears")
    }
}

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
                    Toggle("Shortcuts: ⌃⌥S show / hide · ⌃⌥J jump to who's waiting", isOn: Binding(get: { store.hotkeys }, set: { store.setPref("hotkeys", $0) }))
                }
                Section("Safety") {
                    Toggle("Allow from the panel (off: only Go to tab or Deny)", isOn: Binding(get: { store.panelAllow }, set: { store.setPanelAllow($0) }))
                    Button("Risky commands…") { NSWorkspace.shared.open(URL(fileURLWithPath: Risk.ensureFile())) }
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
            if hover || (why && s.state == "waiting") {
                IconButton(symbol: "arrow.up.forward.square", help: "Jump to \(store.terminalLabel(s))") { store.jump(s) }
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.08 : 0.035)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            // Collapsed "Needs you" line: open it in place to answer. Otherwise: go to the session.
            if why && s.state == "waiting" { store.togglePeek(s) }
            else if store.editing != s.id && store.replying != s.id { store.jump(s) }
        }
        .tip(why && s.state == "waiting" ? "Click to see what it needs and answer here · ↗ jumps to it" : store.rowHelp(s))
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
                Text("Spyglass").font(.system(size: 15, weight: .bold)).foregroundColor(.white).fixedSize()
                Text("\(store.sessions.count)").font(.system(size: 15, weight: .bold)).foregroundColor(.white.opacity(0.4)).fixedSize()
                if store.collapsed && !counts.isEmpty {   // gives way first when the header is tight
                    Text(counts).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).lineLimit(1).layoutPriority(-1)
                }
                Spacer()
                SettingsMenu(store: store)
                // Allow from the panel: open lock = on; closed (orange) = off, every prompt answered in its tab.
                IconButton(symbol: store.panelAllow ? "lock.open" : "lock.fill",
                           help: store.panelAllow
                               ? "Allow from the panel is on. Click to turn it off: prompts then offer only Go to tab or Deny"
                               : "Allow from the panel is off: prompts offer only Go to tab or Deny. Click to turn it back on",
                           tint: store.panelAllow ? .white.opacity(0.75) : .orange) { store.setPanelAllow(!store.panelAllow) }
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
            if store.waitedToday >= 60 {
                HStack(spacing: 5) {
                    Image(systemName: "stopwatch").font(.system(size: 10, weight: .semibold))
                    Text("\(Store.duration(store.waitedToday)) waited on you today")
                }
                .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
                .tip("Time sessions spent waiting on you today (permission prompts, questions), summed across sessions. Starts over at midnight.")
            }
            if store.collapsed && !store.peek.isEmpty {
                // Collapsed: still show which session just rang or needs you; click to jump (and clear it).
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.peek) { s in
                        if store.peekOpen.contains(s.id) { Row(s: s, store: store, inPeek: true) }
                        else { CompactRow(s: s, store: store, why: true) }
                    }
                }
            }
            if !store.collapsed {
                if store.sessions.count >= Store.searchFrom || store.searching { SearchField(store: store) }
                if store.hiddenWaiting > 0 {
                    Button { store.query = "" } label: {
                        Text("\(store.hiddenWaiting) session\(store.hiddenWaiting == 1 ? " needs" : "s need") you (hidden by search) · Show")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).tip("Clear the search")
                }
                if store.searching && store.shown.isEmpty {
                    Text("No sessions match “\(store.query.trimmingCharacters(in: .whitespaces))”").font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5)).padding(.vertical, 6).frame(maxWidth: .infinity)
                } else if store.sessions.isEmpty {
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
                        ForEach(store.shown) { Row(s: $0, store: store) }
                    }
                }
                if !store.shownEnded.isEmpty {
                    HStack(spacing: 6) {
                        Button { store.toggleEnded() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: store.showEnded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Recently ended · \(store.shownEnded.count)").font(.system(size: 11, weight: .semibold))
                            }.foregroundColor(.white.opacity(0.55)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Spacer()
                        if store.showEnded {
                            Button("Clear") { store.clearEnded() }.buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                        }
                    }.padding(.top, 4)
                    if store.showEnded || store.searching { ForEach(store.shownEnded) { EndedRow(s: $0, store: store) } }
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
