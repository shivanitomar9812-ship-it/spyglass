// Spyglass: Entry point: command-line modes first (hooks, json, doctor, tests), else the panel app.
import AppKit

if CommandLine.arguments.count > 1, ["hook", "json", "doctor"].contains(CommandLine.arguments[1]) {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

if MainActor.assumeIsolated({ runTestMode() }) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
