import ArgumentParser
import Foundation

/// Default subcommand: prints the colored banner, quick-start examples, and a
/// live status line. Inspired by `frames` (Apple Frames CLI by Federico Viticci).
struct Welcome: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "welcome",
        abstract: "Show the HomeClaw banner, quick start, and live status"
    )

    @Flag(name: .long, help: "Skip the live status sniff (faster, no socket call)")
    var noStatus = false

    func run() throws {
        // ANSI escapes — zero visible width, safe to use inside padded strings.
        // Suppressed when stdout isn't a TTY (piped, captured), NO_COLOR is set,
        // or TERM=dumb (CI systems and pagers signaling no ANSI rendering),
        // so script callers get clean text instead of raw escape sequences.
        let useColor = isatty(STDOUT_FILENO) != 0
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
        let orange = useColor ? "\u{001B}[38;5;208m" : ""
        let cyan = useColor ? "\u{001B}[36m" : ""
        let green = useColor ? "\u{001B}[32m" : ""
        let red = useColor ? "\u{001B}[31m" : ""
        let dim = useColor ? "\u{001B}[2m" : ""
        let bold = useColor ? "\u{001B}[1m" : ""
        let reset = useColor ? "\u{001B}[0m" : ""

        let banner = #"""
 ▄▄    ▄▄                                   ▄▄▄▄   ▄▄▄▄
 ██    ██                                 ██▀▀▀▀█  ▀▀██
 ██    ██   ▄████▄   ████▄██▄   ▄████▄   ██▀         ██       ▄█████▄ ██      ██
 ████████  ██▀  ▀██  ██ ██ ██  ██▄▄▄▄██  ██          ██       ▀ ▄▄▄██ ▀█  ██  █▀
 ██    ██  ██    ██  ██ ██ ██  ██▀▀▀▀▀▀  ██▄         ██      ▄██▀▀▀██  ██▄██▄██
 ██    ██  ▀██▄▄██▀  ██ ██ ██  ▀██▄▄▄▄█   ██▄▄▄▄█    ██▄▄▄   ██▄▄▄███  ▀██  ██▀
 ▀▀    ▀▀    ▀▀▀▀    ▀▀ ▀▀ ▀▀    ▀▀▀▀▀      ▀▀▀▀      ▀▀▀▀    ▀▀▀▀ ▀▀   ▀▀  ▀▀
"""#

        // Banner in orange
        for line in banner.split(separator: "\n", omittingEmptySubsequences: false) {
            print("\(orange)\(line)\(reset)")
        }

        // Title + tagline
        print("")
        print("  \(bold)HomeClaw CLI\(reset) \(dim)v\(cliVersion)  by Omar Shahine\(reset)")
        print("  \(dim)Control Apple HomeKit accessories from your terminal\(reset)")
        print("")

        // Quick start
        print("  \(bold)Quick start:\(reset)")
        let rows: [(String, String, String)] = [
            ("homeclaw-cli", "ui",                     "Launch the interactive TUI"),
            ("homeclaw-cli", "list",                   "List homes, rooms, and accessories"),
            ("homeclaw-cli", "list --room Kitchen",    "Filter by room"),
            ("homeclaw-cli", "get \"Living Room\"",    "Read accessory state"),
            ("homeclaw-cli", "set \"Desk Lamp\" on",   "Toggle on/off"),
            ("homeclaw-cli", "set \"Desk Lamp\" 50",   "Set brightness or value"),
            ("homeclaw-cli", "search lamp",            "Fuzzy search across accessories"),
            ("homeclaw-cli", "scenes",                 "List scenes"),
            ("homeclaw-cli", "trigger \"Movie Time\"", "Trigger a scene"),
            ("homeclaw-cli", "automations",            "List automations"),
            ("homeclaw-cli", "events --since 1h",      "Tail recent HomeKit events"),
            ("homeclaw-cli", "status",                 "Daemon + HomeKit + webhook status"),
            ("homeclaw-cli", "config",                 "View and edit config"),
        ]

        // Compute width based on raw (un-styled) text so padding stays consistent.
        let cmdColumnWidth = rows
            .map { ($0.0.count + 1 + $0.1.count) }
            .max()
            .map { $0 + 4 } ?? 40

        for (head, tail, desc) in rows {
            let raw = "\(head) \(tail)"
            let pad = String(repeating: " ", count: max(0, cmdColumnWidth - raw.count))
            print("    \(orange)\(head)\(reset) \(cyan)\(tail)\(reset)\(pad)\(desc)")
        }

        // Live status sniff (skippable for speed)
        print("")
        if noStatus {
            print("  \(dim)(use `homeclaw-cli status` for daemon health)\(reset)")
            return
        }

        do {
            let response = try SocketClient.send(command: "status")
            guard response.success,
                  let status = response.data?.value as? [String: Any] else {
                print("  \(red)● HomeClaw not responding\(reset) \(dim)— is the app running?\(reset)")
                return
            }

            let ready = status["ready"] as? Bool ?? false
            let homes = status["homes"] as? Int ?? 0
            let accessories = status["accessories"] as? Int ?? 0
            let version = status["version"] as? String ?? "?"

            if ready {
                let plural = homes == 1 ? "home" : "homes"
                print("  \(green)● HomeKit ready\(reset) \(dim)(v\(version), \(homes) \(plural), \(accessories) accessories)\(reset)")
            } else {
                print("  \(red)● HomeKit not ready\(reset) \(dim)(v\(version), 0 homes — check iCloud sign-in)\(reset)")
            }

            if let webhook = status["webhook"] as? [String: Any],
               let enabled = webhook["enabled"] as? Bool, enabled {
                let circuit = webhook["circuit_state"] as? String ?? "closed"
                if circuit == "softOpen" || circuit == "hardOpen" {
                    print("  \(red)● Webhook circuit \(circuit)\(reset) \(dim)— run `homeclaw-cli config --webhook-reset`\(reset)")
                }
            }
        } catch {
            print("  \(red)● HomeClaw not responding\(reset) \(dim)— is the app running?\(reset)")
        }
    }

    /// Reads the CLI's bundle version when running inside HomeClaw.app/Contents/MacOS/.
    /// Falls back to a hardcoded value when invoked from SPM .build/.
    /// Note: "1.0" is Xcode's default Info.plist placeholder for new targets,
    /// so we treat it as absent. Revisit if a real 1.0 ever ships.
    private var cliVersion: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty, v != "1.0" {
            return v
        }
        return "dev"
    }
}
