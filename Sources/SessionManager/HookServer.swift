import Foundation
import Network
import SwiftUI
import UserNotifications
import AppKit

/// Live status for a session, driven by Claude Code hook events.
enum AgentStatus: String {
    case working           // tool call in flight
    case waiting           // notification (e.g. permission prompt)
    case idle              // Stop event — turn complete
    case unknown           // nothing heard recently
}

struct AgentState: Equatable {
    var status: AgentStatus
    var tool: String?      // last tool name seen
    var updated: Date
}

/// ObservableObject keyed by Claude Code session_id. Mutated on the main
/// actor from the hook server's receive callbacks.
@MainActor
final class AgentStatusStore: ObservableObject {
    @Published private(set) var byId: [String: AgentState] = [:]

    func apply(_ event: HookEvent) {
        let now = Date()
        let previous = byId[event.sessionId]?.status
        switch event.kind {
        case "PreToolUse":
            byId[event.sessionId] = AgentState(status: .working, tool: event.toolName, updated: now)
        case "PostToolUse":
            var s = byId[event.sessionId] ?? AgentState(status: .working, tool: nil, updated: now)
            s.status = .working
            s.tool = nil
            s.updated = now
            byId[event.sessionId] = s
        case "Notification":
            byId[event.sessionId] = AgentState(status: .waiting, tool: event.toolName, updated: now)
            if previous != .waiting {
                AgentNotifier.shared.notifyWaiting(sessionId: event.sessionId, message: event.message)
            }
        case "Stop", "SubagentStop":
            byId[event.sessionId] = AgentState(status: .idle, tool: nil, updated: now)
            if previous == .working || previous == .waiting {
                AgentNotifier.shared.notifyIdle(sessionId: event.sessionId)
            }
        case "UserPromptSubmit":
            byId[event.sessionId] = AgentState(status: .working, tool: nil, updated: now)
        default:
            break
        }
    }

    func state(for id: String) -> AgentState? { byId[id] }
}

/// Decoded hook payload. Only the fields we care about — Claude Code may
/// include others that we safely ignore.
struct HookEvent {
    let kind: String       // from URL path: /hook/PreToolUse etc.
    let sessionId: String
    let toolName: String?
    let message: String?   // from Notification event payloads
}

/// Minimal HTTP/1.1 server on 127.0.0.1:<port>. Not a general HTTP
/// implementation — just enough to receive `POST /hook/<name>` from
/// Claude Code hook commands and reply 200.
@MainActor
final class HookServer: ObservableObject {
    static let defaultPort: UInt16 = 4001

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = HookServer.defaultPort
    @Published private(set) var lastError: String?

    let status: AgentStatusStore
    private var listener: NWListener?

    init(status: AgentStatusStore) {
        self.status = status
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.lastError = nil
                    case .failed(let err):
                        self.running = false
                        self.lastError = "\(err)"
                        self.listener = nil
                    case .cancelled:
                        self.running = false
                    default:
                        break
                    }
                }
            }
            l.start(queue: .main)
            self.listener = l
        } catch {
            self.lastError = "\(error)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: connection handling

    nonisolated private func handle(connection conn: NWConnection) {
        conn.start(queue: .main)
        receiveRequest(conn: conn, buffer: Data())
    }

    nonisolated private func receiveRequest(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let req = Self.tryParseRequest(buf) {
                Task { @MainActor in self.dispatch(request: req) }
                Self.respond(conn: conn, body: "{\"ok\":true}")
                return
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.receiveRequest(conn: conn, buffer: buf)
        }
    }

    nonisolated private static func respond(conn: NWConnection, body: String) {
        let payload = body.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var out = Data(headers.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: request parsing

    struct ParsedRequest {
        let method: String
        let path: String
        let body: Data
    }

    /// Returns a parsed request iff `buf` contains a full HTTP message
    /// (headers + Content-Length bytes of body). Otherwise returns nil.
    nonisolated private static func tryParseRequest(_ buf: Data) -> ParsedRequest? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let v = line.split(separator: ":", maxSplits: 1).last ?? ""
                contentLength = Int(v.trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        let available = buf.count - bodyStart
        if available < contentLength { return nil }
        let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
        return ParsedRequest(method: method, path: path, body: body)
    }

    // MARK: event dispatch

    private func dispatch(request: ParsedRequest) {
        guard request.method == "POST",
              request.path.hasPrefix("/hook/") else { return }
        let kind = String(request.path.dropFirst("/hook/".count))
            .split(separator: "?").first.map(String.init) ?? ""
        guard !kind.isEmpty else { return }

        let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let sessionId = obj["session_id"] as? String ?? ""
        let toolName = obj["tool_name"] as? String
        let message = obj["message"] as? String
        guard !sessionId.isEmpty else { return }

        status.apply(HookEvent(kind: kind, sessionId: sessionId, toolName: toolName, message: message))
    }
}

// MARK: - Hook installer

/// Writes the five hook entries into ~/.claude/settings.json so Claude
/// Code posts to our local server. Merges conservatively with whatever
/// the user already has — never clobbers unrelated keys.
enum HookInstaller {
    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static let events = ["PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "UserPromptSubmit"]

    static func command(for event: String, port: UInt16) -> String {
        // Hook commands receive the JSON payload on stdin. We forward it
        // verbatim to our local server. `--max-time 1` keeps Claude Code
        // from stalling if the app isn't running.
        "cat | /usr/bin/curl -s --max-time 1 -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:\(port)/hook/\(event) >/dev/null 2>&1 || true"
    }

    /// Returns (installed, alreadyPresent) counts.
    @discardableResult
    static func install(port: UInt16) throws -> (installed: Int, alreadyPresent: Int) {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsPath.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        var installed = 0
        var present = 0
        for event in events {
            let cmd = command(for: event, port: port)
            var list = hooks[event] as? [[String: Any]] ?? []
            if containsSessionManagerHook(list) {
                present += 1
                continue
            }
            let entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": cmd
                ]]
            ]
            list.append(entry)
            hooks[event] = list
            installed += 1
        }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsPath, options: .atomic)
        return (installed, present)
    }

    /// Removes our hook entries from settings.json, leaving others alone.
    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsPath),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var list = hooks[event] as? [[String: Any]] else { continue }
            list.removeAll { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String ?? "").contains("/hook/\(event)") &&
                                         ($0["command"] as? String ?? "").contains("127.0.0.1") }
            }
            if list.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = list
            }
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsPath, options: .atomic)
    }

    private static func containsSessionManagerHook(_ list: [[String: Any]]) -> Bool {
        for entry in list {
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            for h in inner {
                let cmd = h["command"] as? String ?? ""
                if cmd.contains("127.0.0.1:") && cmd.contains("/hook/") {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Notifications

/// Posted by AgentNotifier when the user clicks a "needs input"
/// notification banner. ContentView observes this and asks
/// TerminalTabs to open / focus the matching session.
extension Notification.Name {
    static let focusSession = Notification.Name("SessionManager.focusSession")
}

/// Fires macOS notifications (and bounces the dock) when a session
/// transitions into "needs input" or finishes its turn. Throttled per
/// session so a chatty hook script can't spam the user.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()

    private var authorized = false
    private var lastFired: [String: Date] = [:]
    private let throttle: TimeInterval = 10

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    // Show the banner even if the app is foregrounded — otherwise
    // notifications are silently swallowed when the user already has
    // Session Manager open in another desktop / space.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let sid = info["session_id"] as? String {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .focusSession,
                    object: nil,
                    userInfo: ["session_id": sid]
                )
            }
        }
        completionHandler()
    }

    func notifyWaiting(sessionId: String, message: String?) {
        guard shouldFire(sessionId) else { return }
        let title = "Claude needs input"
        let body = (message?.isEmpty == false ? message! : "Permission or input required.")
        post(title: title, body: body, sessionId: sessionId)
        // Bounce the dock icon once — draws the eye without stealing focus.
        NSApp.requestUserAttention(.informationalRequest)
    }

    func notifyIdle(sessionId: String) {
        // Intentionally a no-op: every assistant turn ends in Stop, so
        // bouncing/banner here would be constant noise. Kept as a hook
        // for future behavior (e.g. only notify after long-running turns).
    }

    private func shouldFire(_ sessionId: String) -> Bool {
        let now = Date()
        if let last = lastFired[sessionId], now.timeIntervalSince(last) < throttle {
            return false
        }
        lastFired[sessionId] = now
        return true
    }

    private func post(title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session_id": sessionId]
        let req = UNNotificationRequest(identifier: "waiting-\(sessionId)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
