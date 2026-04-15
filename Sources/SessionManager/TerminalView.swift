import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView.
/// Spawns a shell that runs a command and exposes its lifecycle.
struct EmbeddedTerminal: NSViewRepresentable {
    let command: String        // e.g. "claude --resume <uuid>"
    let cwd: String
    @Binding var isRunning: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        context.coordinator.terminal = term

        // Match macOS dark style
        term.nativeBackgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
        term.nativeForegroundColor = NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.95, alpha: 1)

        // GUI apps don't inherit the user's interactive PATH. Build a sensible
        // PATH that covers Homebrew (Apple Silicon + Intel), system bin, and
        // ~/.local/bin / ~/bin where Claude Code is typically installed.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let home = NSHomeDirectory()
        let extraPaths = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        // Find the existing PATH entry and prepend our paths
        var foundPath = false
        env = env.map { entry -> String in
            if entry.hasPrefix("PATH=") {
                foundPath = true
                let existing = String(entry.dropFirst("PATH=".count))
                return "PATH=" + (extraPaths + [existing]).joined(separator: ":")
            }
            return entry
        }
        if !foundPath {
            env.append("PATH=" + extraPaths.joined(separator: ":"))
        }
        env.append("HOME=\(home)")
        env.append("LANG=en_US.UTF-8")

        // -l (login) sources .zprofile/.zshenv; -i (interactive) sources .zshrc
        // so users with `claude` aliased in .zshrc still work.
        let shellArgs = ["-l", "-i", "-c", command]
        term.startProcess(executable: "/bin/zsh", args: shellArgs,
                          environment: env, execName: "zsh")

        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isRunning: $isRunning) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminal: LocalProcessTerminalView?
        @Binding var isRunning: Bool
        init(isRunning: Binding<Bool>) {
            self._isRunning = isRunning
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
}

/// View shown in the main panel: the embedded terminal plus a small status bar.
struct TerminalPaneView: View {
    let session: Session
    @State private var isRunning: Bool = true
    @State private var key = UUID()  // forces re-creation on restart

    var quotedCwd: String {
        session.cwd.replacingOccurrences(of: "\"", with: "\\\"")
    }

    var isDraft: Bool { session.id.hasPrefix("draft-") }

    var command: String {
        let claudePath = ClaudeLocator.resolvePath() ?? "claude"
        if isDraft {
            // Brand-new session: the synthetic Session stores its cwd in
            // `path`, not the projectDir-derived `cwd` getter.
            let dir = session.path.path
            let escaped = dir.replacingOccurrences(of: "\"", with: "\\\"")
            return "cd \"\(escaped)\" && exec \"\(claudePath)\""
        }
        let cwdExists = FileManager.default.fileExists(atPath: session.cwd)
        let cwd = cwdExists ? session.cwd : NSHomeDirectory()
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(escaped)\" && exec \"\(claudePath)\" --resume \(session.id)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Circle()
                    .fill(isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(session.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(isDraft ? session.path.path : session.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isRunning {
                    Button {
                        isRunning = true
                        key = UUID()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            Divider()

            EmbeddedTerminal(command: command,
                             cwd: isDraft ? session.path.path : session.cwd,
                             isRunning: $isRunning)
                .id(key)
        }
    }
}

/// Finds the `claude` binary across nvm, ~/.local/bin, Homebrew, etc.
enum ClaudeLocator {
    private static var cached: String?

    static func resolvePath() -> String? {
        if let c = cached { return c }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nodes = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for v in nodes {
                candidates.append("\(nvmDir)/\(v)/bin/claude")
            }
        }
        candidates.append("\(home)/.fnm/aliases/default/bin/claude")
        candidates.append("\(home)/.volta/bin/claude")
        candidates.append("\(home)/.asdf/shims/claude")

        for c in candidates where fm.isExecutableFile(atPath: c) {
            cached = c
            return c
        }

        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-l", "-i", "-c", "command -v claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && fm.isExecutableFile(atPath: path) {
                cached = path
                return path
            }
        } catch {}
        return nil
    }
}
