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

        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let shellArgs = ["-l", "-c", command]
        term.startProcess(executable: "/bin/zsh", args: shellArgs,
                          environment: env, execName: "zsh")

        // Set working dir via the spawned shell command (zsh uses the parent's cwd by default;
        // we cd via the command string when wiring it from SessionManager).
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

    var command: String {
        // cd to the original cwd (fallback to home) and exec claude --resume
        let cwdExists = FileManager.default.fileExists(atPath: session.cwd)
        let cwd = cwdExists ? session.cwd : NSHomeDirectory()
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(escaped)\" && exec claude --resume \(session.id)"
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
                Text(session.cwd)
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

            EmbeddedTerminal(command: command, cwd: session.cwd, isRunning: $isRunning)
                .id(key)
        }
    }
}
