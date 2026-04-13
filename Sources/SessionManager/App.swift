import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct Session: Identifiable, Hashable {
    let id: String
    let path: URL
    let projectDir: URL
    let mtime: Date
    var customName: String = ""
    var claudeName: String = ""
    var firstPrompt: String = ""
    var lastCtx: Int = 0
    var msgCount: Int = 0

    var metaPath: URL { path.deletingPathExtension().appendingPathExtension("meta.json") }
    var siblingDir: URL { projectDir.appendingPathComponent(id) }

    var cwd: String {
        let n = projectDir.lastPathComponent
        let trimmed = n.hasPrefix("-") ? String(n.dropFirst()) : n
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayName: String {
        if !customName.isEmpty { return customName }
        if !claudeName.isEmpty { return claudeName }
        return firstPrompt.isEmpty ? "(empty)" : firstPrompt
    }

    var effectiveName: String {
        customName.isEmpty ? claudeName : customName
    }
}

// MARK: - Loader

enum SessionLoader {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }
    static var trash: URL { root.appendingPathComponent(".trash") }
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }

    static func loadClaudeRenames() -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return out
        }
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String else { continue }
            let name = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[sid] = name }
        }
        return out
    }

    static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = content as? [[String: Any]] {
            var parts: [String] = []
            for p in arr {
                let t = p["type"] as? String
                if t == "text", let txt = p["text"] as? String { parts.append(txt) }
                else if t == "tool_use", let n = p["name"] as? String { parts.append("[tool: \(n)]") }
                else if t == "tool_result" { parts.append("[tool result]") }
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func firstUserText(_ url: URL, limit: Int = 500) -> String {
        guard let str = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if (obj["type"] as? String) != "user" { continue }
            let msg = obj["message"] as? [String: Any]
            let text = extractText(msg?["content"])
            if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("Caveat:") { continue }
            return String(text.prefix(limit))
        }
        return ""
    }

    static func stats(_ url: URL) -> (lastCtx: Int, msgs: Int) {
        guard let str = try? String(contentsOf: url, encoding: .utf8) else { return (0, 0) }
        var lastCtx = 0
        var msgs = 0
        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let t = obj["type"] as? String
            if t != "user" && t != "assistant" { continue }
            msgs += 1
            if t == "assistant" {
                let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
                let ctx = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                if ctx > 0 { lastCtx = ctx }
            }
        }
        return (lastCtx, msgs)
    }

    struct Turn: Identifiable {
        let id = UUID()
        let role: String
        let text: String
    }

    static func transcript(_ url: URL, maxMessages: Int = 60) -> [Turn] {
        guard let str = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var turns: [Turn] = []
        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
            if turns.count >= maxMessages { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let t = obj["type"] as? String
            if t != "user" && t != "assistant" { continue }
            let msg = obj["message"] as? [String: Any]
            let text = extractText(msg?["content"])
            if text.isEmpty { continue }
            if t == "user" && (text.hasPrefix("<") || text.hasPrefix("Caveat:")) { continue }
            let snippet = text.count <= 1500 ? text : String(text.prefix(1500)) + "…"
            turns.append(Turn(role: t!, text: snippet))
        }
        return turns
    }

    static func loadAll() -> [Session] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        let renames = loadClaudeRenames()
        var out: [Session] = []
        for proj in projects {
            let name = proj.lastPathComponent
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: proj.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let attrs = try? fm.attributesOfItem(atPath: f.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
                let uuid = f.deletingPathExtension().lastPathComponent
                var s = Session(id: uuid, path: f, projectDir: proj, mtime: mtime,
                                claudeName: renames[uuid] ?? "")
                let meta = s.metaPath
                if let data = try? Data(contentsOf: meta),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    s.customName = obj["name"] as? String ?? ""
                }
                s.firstPrompt = firstUserText(f)
                let st = stats(f)
                s.lastCtx = st.lastCtx
                s.msgCount = st.msgs
                out.append(s)
            }
        }
        out.sort { $0.mtime > $1.mtime }
        return out
    }

    static func trashSession(_ s: Session) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let projTrash = trash.appendingPathComponent(s.projectDir.lastPathComponent)
        try fm.createDirectory(at: projTrash, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try fm.moveItem(at: s.path, to: projTrash.appendingPathComponent("\(s.id).\(stamp).jsonl"))
        if fm.fileExists(atPath: s.metaPath.path) {
            try fm.moveItem(at: s.metaPath, to: projTrash.appendingPathComponent("\(s.id).\(stamp).meta.json"))
        }
        if fm.fileExists(atPath: s.siblingDir.path) {
            try fm.moveItem(at: s.siblingDir, to: projTrash.appendingPathComponent("\(s.id).\(stamp)"))
        }
    }

    static func saveCustomName(_ s: Session, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let payload: [String: Any] = ["name": trimmed, "tags": []]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: s.metaPath)
    }

    /// Export a session as a .tar.gz bundle compatible with `cc-sessions import`
    /// so another Mac running this app (or the CLI) can import and resume it.
    static func exportBundle(_ s: Session) -> URL? {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("cc-export-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }

            let manifest: [String: Any] = [
                "uuid": s.id,
                "original_cwd": s.cwd,
                "original_home": fm.homeDirectoryForCurrentUser.path,
                "original_project_dir": s.projectDir.lastPathComponent,
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "claude_name": s.claudeName,
                "has_meta": fm.fileExists(atPath: s.metaPath.path),
                "has_sibling_dir": fm.fileExists(atPath: s.siblingDir.path)
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            try manifestData.write(to: stage.appendingPathComponent("manifest.json"))

            try fm.copyItem(at: s.path, to: stage.appendingPathComponent("session.jsonl"))
            if fm.fileExists(atPath: s.metaPath.path) {
                try fm.copyItem(at: s.metaPath, to: stage.appendingPathComponent("meta.json"))
            }
            if fm.fileExists(atPath: s.siblingDir.path) {
                try fm.copyItem(at: s.siblingDir, to: stage.appendingPathComponent("session_dir"))
            }

            let outURL = fm.temporaryDirectory
                .appendingPathComponent("cc-session-\(s.id.prefix(8)).tar.gz")
            try? fm.removeItem(at: outURL)

            let task = Process()
            task.launchPath = "/usr/bin/tar"
            task.currentDirectoryURL = stage
            task.arguments = ["-czf", outURL.path, "."]
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? outURL : nil
        } catch {
            return nil
        }
    }

    enum ImportError: Error, LocalizedError {
        case extractFailed
        case missingManifest
        case alreadyExists(URL)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .extractFailed: return "Failed to extract bundle"
            case .missingManifest: return "Bundle is missing manifest.json (not a cc-session bundle?)"
            case .alreadyExists(let u): return "A session with the same id already exists at \(u.path)"
            case .writeFailed(let m): return "Write failed: \(m)"
            }
        }
    }

    struct ImportResult {
        let uuid: String
        let cwd: String
        let installedAt: URL
    }

    /// Import a .tar.gz bundle, remapping paths so the recipient can resume locally.
    static func importBundle(_ tarball: URL, intoCwd newCwd: String) throws -> ImportResult {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("cc-import-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let task = Process()
        task.launchPath = "/usr/bin/tar"
        task.currentDirectoryURL = stage
        task.arguments = ["-xzf", tarball.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ImportError.extractFailed }

        let manifestURL = stage.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path),
              let mData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
              let uuid = manifest["uuid"] as? String else {
            throw ImportError.missingManifest
        }

        let origCwd = manifest["original_cwd"] as? String ?? ""
        let origHome = manifest["original_home"] as? String ?? ""
        let resolvedCwd = (newCwd as NSString).expandingTildeInPath
        let newHome = fm.homeDirectoryForCurrentUser.path

        let projectDirName = "-" + resolvedCwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        let targetDir = root.appendingPathComponent(projectDirName)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetJsonl = targetDir.appendingPathComponent("\(uuid).jsonl")
        if fm.fileExists(atPath: targetJsonl.path) {
            throw ImportError.alreadyExists(targetJsonl)
        }

        do {
            var src = try String(contentsOf: stage.appendingPathComponent("session.jsonl"), encoding: .utf8)
            if !origCwd.isEmpty && origCwd != resolvedCwd {
                src = src.replacingOccurrences(of: origCwd, with: resolvedCwd)
            }
            if !origHome.isEmpty && origHome != newHome {
                src = src.replacingOccurrences(of: origHome, with: newHome)
            }
            try src.write(to: targetJsonl, atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.writeFailed(error.localizedDescription)
        }

        let metaSrc = stage.appendingPathComponent("meta.json")
        if fm.fileExists(atPath: metaSrc.path) {
            try? fm.copyItem(at: metaSrc, to: targetDir.appendingPathComponent("\(uuid).meta.json"))
        }
        let dirSrc = stage.appendingPathComponent("session_dir")
        if fm.fileExists(atPath: dirSrc.path) {
            try? fm.copyItem(at: dirSrc, to: targetDir.appendingPathComponent(uuid))
        }

        return ImportResult(uuid: uuid, cwd: resolvedCwd, installedAt: targetJsonl)
    }

    /// Export selected sessions as plain-text transcripts to a temp file, return URL.
    static func exportAsText(_ sessions: [Session]) -> URL? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("session-export-\(Int(Date().timeIntervalSince1970)).txt")
        var out = ""
        for s in sessions {
            out += "════════════════════════════════════════════════════════\n"
            out += "Session: \(s.displayName)\n"
            out += "uuid:    \(s.id)\n"
            out += "cwd:     \(s.cwd)\n"
            out += "when:    \(s.mtime)\n"
            out += "════════════════════════════════════════════════════════\n\n"
            for turn in transcript(s.path, maxMessages: 1000) {
                out += "── \(turn.role.uppercased()) ──\n\(turn.text)\n\n"
            }
            out += "\n"
        }
        do {
            try out.write(to: tmp, atomically: true, encoding: .utf8)
            return tmp
        } catch { return nil }
    }
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var filter: String = ""
    @Published var loading: Bool = false
    @Published var selectedProject: String? = nil  // nil = all

    var projects: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for s in sessions { counts[s.projectName, default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var filtered: [Session] {
        let needle = filter.lowercased().trimmingCharacters(in: .whitespaces)
        return sessions.filter { s in
            if let proj = selectedProject, s.projectName != proj { return false }
            if needle.isEmpty { return true }
            return s.displayName.lowercased().contains(needle)
                || s.id.lowercased().contains(needle)
                || s.cwd.lowercased().contains(needle)
        }
    }

    func reload() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let result = SessionLoader.loadAll()
            await MainActor.run {
                self.sessions = result
                self.loading = false
            }
        }
    }

    func delete(_ ids: Set<String>) -> (deleted: Int, errors: [String]) {
        var ok = 0
        var errors: [String] = []
        for s in sessions where ids.contains(s.id) {
            do {
                try SessionLoader.trashSession(s)
                ok += 1
            } catch {
                errors.append("\(s.id.prefix(8)): \(error.localizedDescription)")
            }
        }
        reload()
        return (ok, errors)
    }

    func rename(_ s: Session, to name: String) throws {
        try SessionLoader.saveCustomName(s, name: name)
        reload()
    }
}

// MARK: - Helpers

func fmtTokens(_ n: Int) -> String {
    if n <= 0 { return "—" }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

func fmtTime(_ d: Date) -> String {
    let now = Date()
    let delta = now.timeIntervalSince(d)
    if delta >= 86_400 * 7 {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }
    if delta >= 86_400 {
        let days = Int(delta) / 86_400
        return "\(days)d ago"
    }
    let h = Int(delta) / 3600
    if h >= 1 { return "\(h)h ago" }
    let m = Int(delta) / 60
    return m > 0 ? "\(m)m ago" : "just now"
}

// MARK: - Updater (GitHub Releases)

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
    }
}

@MainActor
final class Updater: ObservableObject {
    static let owner = "OwenCope"
    static let repo = "claude-code-session-manager"

    @Published var available: GitHubRelease?
    @Published var checking = false
    @Published var status: String?
    @Published var downloadProgress: Double = 0

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    func check(silent: Bool = false) async {
        checking = true
        defer { checking = false }
        let urlStr = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("session-manager-app", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let cmp = Self.compareVersions(currentVersion, release.tagName)
            if cmp == .orderedAscending {
                self.available = release
                self.status = "Update available: \(release.tagName)"
            } else {
                self.available = nil
                if !silent { self.status = "You're on the latest version (\(currentVersion))" }
            }
        } catch {
            if !silent { self.status = "Update check failed: \(error.localizedDescription)" }
        }
    }

    /// Downloads the DMG asset and opens it in Finder, then quits the app so the
    /// user can drag the new version into /Applications.
    func downloadAndOpen() async {
        guard let release = available,
              let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: asset.browserDownloadUrl) else {
            self.status = "No DMG asset on the latest release"
            return
        }
        self.status = "Downloading \(asset.name)..."
        downloadProgress = 0
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(asset.name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            NSWorkspace.shared.open(dest)
            self.status = "Opened installer. Drag the new app into Applications, then relaunch."
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSApplication.shared.terminate(nil)
        } catch {
            self.status = "Download failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Resume / Terminal

func resumeInTerminal(_ s: Session) {
    let cwd = FileManager.default.fileExists(atPath: s.cwd) ? s.cwd
        : FileManager.default.homeDirectoryForCurrentUser.path
    let escapedCwd = cwd.replacingOccurrences(of: "\"", with: "\\\"")
    let cmd = "cd \"\(escapedCwd)\" && claude --resume \(s.id)"
    let asCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "Terminal"
        activate
        do script "\(asCmd)"
    end tell
    """
    if let appleScript = NSAppleScript(source: script) {
        var err: NSDictionary?
        appleScript.executeAndReturnError(&err)
    }
}

// MARK: - Project picker (toolbar dropdown)

struct ProjectPicker: View {
    @EnvironmentObject var store: SessionStore

    var label: String {
        store.selectedProject ?? "All Projects"
    }

    var body: some View {
        Menu {
            Button {
                store.selectedProject = nil
            } label: {
                HStack {
                    Text("All Projects")
                    Spacer()
                    Text("\(store.sessions.count)")
                }
            }
            Divider()
            ForEach(store.projects, id: \.name) { p in
                Button {
                    store.selectedProject = p.name
                } label: {
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text("\(p.count)")
                    }
                }
            }
        } label: {
            Label(label, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Detail / table

struct SessionTable: View {
    @EnvironmentObject var store: SessionStore
    @Binding var selection: Set<String>
    let onResume: (Session) -> Void
    let onRename: (Session) -> Void
    let onDeleteRequest: () -> Void

    var body: some View {
        Table(store.filtered, selection: $selection) {
            TableColumn("") { s in
                Image(systemName: s.customName.isEmpty ? "bubble.left.and.bubble.right" : "star.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(s.customName.isEmpty ? Color.accentColor : .yellow)
            }
            .width(24)

            TableColumn("Name") { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayName)
                        .lineLimit(1)
                        .font(.body)
                    Text(s.firstPrompt.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .width(min: 200, ideal: 360)

            TableColumn("Project") { s in
                Text(s.projectName).font(.caption).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Updated") { s in
                Text(fmtTime(s.mtime)).font(.caption).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Ctx") { s in
                Text(fmtTokens(s.lastCtx))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)

            TableColumn("ID") { s in
                Text(String(s.id.prefix(8)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = store.sessions.first(where: { $0.id == id }) {
                Button { onResume(s) } label: { Label("Resume in Terminal", systemImage: "play.fill") }
                Button { onRename(s) } label: { Label("Rename…", systemImage: "pencil") }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([s.path])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                if let url = SessionLoader.exportAsText([s]) {
                    ShareLink("Share Transcript", item: url)
                }
                Divider()
            }
            if !ids.isEmpty {
                let chosen = store.sessions.filter { ids.contains($0.id) }
                if let url = SessionLoader.exportAsText(chosen) {
                    ShareLink(item: url) {
                        Label("Share \(ids.count) Transcript\(ids.count == 1 ? "" : "s")",
                              systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    onDeleteRequest()
                } label: {
                    Label("Delete \(ids.count)…", systemImage: "trash")
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let s = store.sessions.first(where: { $0.id == id }) {
                onResume(s)
            }
        }
    }
}

// MARK: - Inspector / preview

struct InspectorView: View {
    @EnvironmentObject var store: SessionStore
    let selection: Set<String>

    var session: Session? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let s = session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.displayName)
                                .font(.title3.weight(.semibold))
                                .lineLimit(3)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.tertiary)
                                Text(s.cwd)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        statBar(for: s)

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(SessionLoader.transcript(s.path)) { turn in
                                turnView(turn)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.background)
            } else if selection.count > 1 {
                ContentUnavailableViewCompat(
                    title: "\(selection.count) sessions selected",
                    systemImage: "checklist",
                    description: "Use the toolbar to share or delete the selected sessions."
                )
            } else {
                ContentUnavailableViewCompat(
                    title: "No Selection",
                    systemImage: "sidebar.right",
                    description: "Select a session to preview it."
                )
            }
        }
        .frame(minWidth: 320)
    }

    @ViewBuilder
    func statBar(for s: Session) -> some View {
        HStack(spacing: 14) {
            statBlock(label: "Updated", value: fmtTime(s.mtime), icon: "clock")
            statBlock(label: "Context", value: fmtTokens(s.lastCtx), icon: "rectangle.stack")
            statBlock(label: "Messages", value: "\(s.msgCount)", icon: "bubble.left.and.bubble.right")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    func statBlock(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value).font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func turnView(_ turn: SessionLoader.Turn) -> some View {
        let isUser = turn.role == "user"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isUser ? "person.circle.fill" : "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isUser ? Color.accentColor : .purple)
                Text(isUser ? "You" : "Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(turn.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08))
                )
        }
    }
}

// Backport-friendly empty-state view
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title3.weight(.semibold))
            Text(description)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Root content

@MainActor
final class TerminalTabs: ObservableObject {
    @Published var open: [Session] = []
    @Published var active: String?

    func openOrFocus(_ s: Session) {
        if !open.contains(where: { $0.id == s.id }) { open.append(s) }
        active = s.id
    }
    func close(_ id: String) {
        open.removeAll { $0.id == id }
        if active == id { active = open.last?.id }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var updater: Updater
    @StateObject private var tabs = TerminalTabs()
    @State private var showUpdatePrompt = false
    @State private var selection: Set<String> = []
    @State private var renameTarget: Session?
    @State private var renameValue: String = ""
    @State private var confirmDelete: Bool = false
    @State private var notice: String?
    @State private var inspectorVisible: Bool = true
    @State private var importPending: URL?
    @State private var importCwd: String = ""

    var selectedSessions: [Session] {
        store.sessions.filter { selection.contains($0.id) }
    }

    /// Single-session bundle for ShareLink (importable on the other side).
    var shareBundleURL: URL? {
        guard selectedSessions.count == 1 else { return nil }
        return SessionLoader.exportBundle(selectedSessions[0])
    }

    /// Plain-text transcript for read-only sharing.
    var shareTranscriptURL: URL? {
        guard !selectedSessions.isEmpty else { return nil }
        return SessionLoader.exportAsText(selectedSessions)
    }

    var body: some View {
        HSplitView {
            SidebarSessionList(selection: $selection)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                .environmentObject(tabs)

            VStack(spacing: 0) {
                TabbedTerminalView()
                    .environmentObject(tabs)
                    .environmentObject(store)
                if let n = notice {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(n).font(.caption)
                        Spacer()
                        Button { notice = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                }
            }
            .frame(minWidth: 500)
        }
        .navigationTitle("Claude Code Sessions")
        .navigationSubtitle("\(tabs.open.count) running · \(store.filtered.count) total")
        .inspector(isPresented: $inspectorVisible) {
            InspectorView(selection: selection)
                .inspectorColumnWidth(min: 320, ideal: 420, max: 600)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ProjectPicker()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        if let id = selection.first, let s = store.sessions.first(where: { $0.id == id }) {
                            tabs.openOrFocus(s)
                        }
                    } label: { Label("Resume in App", systemImage: "play.fill") }
                        .disabled(selection.count != 1)
                        .help("Open the session in an embedded terminal tab (⏎)")
                        .keyboardShortcut(.return, modifiers: [])

                    Button {
                        if let id = selection.first, let s = store.sessions.first(where: { $0.id == id }) {
                            resumeInTerminal(s)
                        }
                    } label: { Label("Open in Terminal.app", systemImage: "rectangle.and.text.magnifyingglass") }
                        .disabled(selection.count != 1)
                        .help("Open in the system Terminal (⌘⏎)")
                        .keyboardShortcut(.return, modifiers: .command)

                    Button {
                        if let id = selection.first, let s = store.sessions.first(where: { $0.id == id }) {
                            renameTarget = s
                            renameValue = s.customName
                        }
                    } label: { Label("Rename", systemImage: "pencil") }
                        .disabled(selection.count != 1)

                    Menu {
                        if let url = shareBundleURL {
                            ShareLink(item: url,
                                      preview: SharePreview("Claude session bundle",
                                                            image: Image(systemName: "shippingbox.fill"))) {
                                Label("Share Importable Bundle (.tar.gz)", systemImage: "shippingbox")
                            }
                        } else {
                            Text("Select 1 session to share a bundle")
                                .foregroundStyle(.tertiary)
                        }
                        if let url = shareTranscriptURL {
                            ShareLink(item: url) {
                                Label("Share Transcript (text)", systemImage: "doc.text")
                            }
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(selection.isEmpty)
                    .help("Share session — bundle is openable on another Mac via Import…")

                    Button {
                        let panel = NSOpenPanel()
                        panel.title = "Import Session Bundle"
                        panel.allowedContentTypes = [
                            UTType(filenameExtension: "gz") ?? .data,
                            UTType(filenameExtension: "tar") ?? .data,
                            .data
                        ]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            importPending = url
                            importCwd = FileManager.default.homeDirectoryForCurrentUser.path
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .help("Import a .tar.gz session bundle from another Mac")

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: { Label("Delete", systemImage: "trash") }
                        .disabled(selection.isEmpty)
                        .keyboardShortcut(.delete, modifiers: .command)

                    Button { store.reload() } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Reload sessions (⌘R)")

                    Button {
                        let url = SessionLoader.trash
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Show Trash", systemImage: "trash.circle")
                    }
                    .help("Open the app trash folder in Finder (~/.claude/projects/.trash)")

                    if updater.available != nil {
                        Button {
                            showUpdatePrompt = true
                        } label: {
                            Label("Update \(updater.available?.tagName ?? "")",
                                  systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .help("A new version is available")
                    }

                    Button { inspectorVisible.toggle() } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help("Toggle inspector")
                }
            }
        .frame(minWidth: 1100, minHeight: 640)
        .onAppear { store.reload() }
        .sheet(item: $renameTarget) { s in
            RenameSheet(session: s, value: $renameValue) { newValue in
                do {
                    try store.rename(s, to: newValue)
                    notice = newValue.isEmpty ? "Cleared custom name" : "Renamed to “\(newValue)”"
                } catch {
                    notice = "Save failed: \(error.localizedDescription)"
                }
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
            }
        }
        .alert("Delete \(selection.count) session\(selection.count == 1 ? "" : "s")?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { performDelete() }
        } message: {
            Text("Files will be moved to ~/.claude/projects/.trash and can be restored manually.")
        }
        .alert("Update Available",
               isPresented: $showUpdatePrompt,
               presenting: updater.available) { release in
            Button("Cancel", role: .cancel) {}
            Button("Download & Install") {
                Task { await updater.downloadAndOpen() }
            }
            Button("View Release Notes") {
                if let u = URL(string: release.htmlUrl) { NSWorkspace.shared.open(u) }
            }
        } message: { release in
            Text("Version \(release.tagName) is available. You have \(updater.currentVersion).\n\n"
                 + (release.body?.prefix(400).description ?? ""))
        }
        .onChange(of: updater.available?.tagName) { _, new in
            if new != nil { showUpdatePrompt = true }
        }
        .sheet(item: $importPending) { url in
            ImportSheet(bundleURL: url, cwd: $importCwd) { finalCwd in
                do {
                    let result = try SessionLoader.importBundle(url, intoCwd: finalCwd)
                    notice = "Imported \(result.uuid.prefix(8)) → \(result.cwd)"
                    store.reload()
                } catch {
                    notice = "Import failed: \(error.localizedDescription)"
                }
                importPending = nil
            } onCancel: {
                importPending = nil
            }
        }
    }

    func performDelete() {
        let result = store.delete(selection)
        let n = result.deleted
        notice = "Moved \(n) session\(n == 1 ? "" : "s") to trash"
            + (result.errors.isEmpty ? "" : " · \(result.errors.count) error(s)")
        selection.removeAll()
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct ImportSheet: View {
    let bundleURL: URL
    @Binding var cwd: String
    let onImport: (String) -> Void
    let onCancel: () -> Void

    var manifestPreview: (uuid: String, originalCwd: String)? {
        // Quick peek: extract manifest.json into a temp dir using `tar -xzOf` (stream one file)
        let task = Process()
        let pipe = Pipe()
        task.launchPath = "/usr/bin/tar"
        task.arguments = ["-xzOf", bundleURL.path, "./manifest.json"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let uuid = obj["uuid"] as? String,
           let cwd = obj["original_cwd"] as? String {
            return (uuid, cwd)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading) {
                    Text("Import Session").font(.headline)
                    Text(bundleURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let m = manifestPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(m.uuid.prefix(8)), systemImage: "number")
                        .font(.callout)
                    Label(m.originalCwd, systemImage: "folder.badge.gearshape")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }

            Text("Local path for this project on this Mac:")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("/Users/you/path/to/project", text: $cwd)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        cwd = url.path
                    }
                }
            }
            .frame(width: 460)

            Text("Paths inside the session will be rewritten from the original cwd to this one so `claude --resume` works locally.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 460, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.escape)
                Button("Import") { onImport(cwd) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(cwd.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
    }
}

struct RenameSheet: View {
    let session: Session
    @Binding var value: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading) {
                    Text("Rename Session").font(.headline)
                    Text(String(session.id.prefix(8)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Custom name (empty to clear)", text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .frame(width: 380)
                .onSubmit { onSave(value.trimmingCharacters(in: .whitespaces)) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.escape)
                Button("Save") { onSave(value.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .onAppear { focused = true }
    }
}

// MARK: - App

@main
struct SessionManagerApp: App {
    @StateObject var store = SessionStore()
    @StateObject var updater = Updater()

    var body: some Scene {
        WindowGroup("Claude Sessions") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updater)
                .background(WindowAccessor())
                .task {
                    // Silent check on launch
                    await updater.check(silent: true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(silent: false) }
                }
                Button("Reload Sessions") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

/// Sets the window background to a translucent material so the toolbar blends in.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let win = v.window {
                win.titlebarAppearsTransparent = false
                win.titleVisibility = .visible
                win.isMovableByWindowBackground = true
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
