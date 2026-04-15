import SwiftUI

/// One bucket in the sectioned sidebar.
enum SessionSection: String, CaseIterable, Identifiable {
    case pinned     = "Pinned"
    case needsInput = "Needs input"
    case working    = "Working"
    case recent     = "Recent"
    case older      = "Older"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pinned:     return "pin.fill"
        case .needsInput: return "exclamationmark.bubble.fill"
        case .working:    return "bolt.fill"
        case .recent:     return "clock.fill"
        case .older:      return "tray.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pinned:     return .pink
        case .needsInput: return .yellow
        case .working:    return .orange
        case .recent:     return .accentColor
        case .older:      return .secondary
        }
    }
}

/// CliDeck-style sidebar: sessions are bucketed into collapsible sections
/// by live status, with Messages-style rows underneath each header.
struct SidebarSessionList: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TerminalTabs
    @EnvironmentObject var agentStatus: AgentStatusStore
    @Binding var selection: Set<String>

    @State private var collapsed: Set<SessionSection> = []

    private func bucket(for s: Session) -> SessionSection {
        if store.isPinned(s.id) { return .pinned }
        if let st = agentStatus.state(for: s.id),
           Date().timeIntervalSince(st.updated) < 300 {
            switch st.status {
            case .waiting: return .needsInput
            case .working: return .working
            default: break
            }
        }
        if s.isActive { return .working }
        if Date().timeIntervalSince(s.mtime) < 86_400 { return .recent }
        return .older
    }

    private var grouped: [(SessionSection, [Session])] {
        var buckets: [SessionSection: [Session]] = [:]
        for s in store.filtered { buckets[bucket(for: s), default: []].append(s) }
        return SessionSection.allCases.compactMap { sec in
            guard let list = buckets[sec], !list.isEmpty else { return nil }
            return (sec, list)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search sessions", text: $store.filter)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)

            HStack {
                Text(store.selectedProject ?? "All Projects")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.filtered.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            List(selection: Binding(
                get: { selection.first },
                set: { newValue in
                    if let v = newValue { selection = [v] }
                    else { selection = [] }
                }
            )) {
                ForEach(grouped, id: \.0) { (section, items) in
                    Section {
                        if !collapsed.contains(section) {
                            ForEach(items) { s in
                                SidebarRow(session: s,
                                           isOpenAsTab: tabs.open.contains(where: { $0.id == s.id }),
                                           agent: agentStatus.state(for: s.id),
                                           pinned: store.isPinned(s.id),
                                           onOpenInApp: { tabs.openOrFocus(s) },
                                           onOpenInTerminal: { resumeInTerminal(s) },
                                           onTogglePin: { store.togglePin(s.id) })
                                    .tag(s.id)
                                    .contextMenu {
                                        Button("Open in App") { tabs.openOrFocus(s) }
                                        Button("Open in Terminal.app") { resumeInTerminal(s) }
                                        Divider()
                                        Button(store.isPinned(s.id) ? "Unpin" : "Pin to top") {
                                            store.togglePin(s.id)
                                        }
                                    }
                            }
                        }
                    } header: {
                        SectionHeader(section: section,
                                      count: items.count,
                                      collapsed: collapsed.contains(section)) {
                            if collapsed.contains(section) {
                                collapsed.remove(section)
                            } else {
                                collapsed.insert(section)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 60)
        }
        .background(.regularMaterial)
    }
}

/// Collapsible header row for each sidebar section: chevron, icon, name,
/// count badge. Clicking anywhere on the header toggles the section.
struct SectionHeader: View {
    let section: SessionSection
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: section.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(section.tint)
            Text(section.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }
}

struct SidebarRow: View {
    let session: Session
    let isOpenAsTab: Bool
    let agent: AgentState?
    var pinned: Bool = false
    var onOpenInApp: (() -> Void)? = nil
    var onOpenInTerminal: (() -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil

    @State private var hovering = false

    var avatarColor: Color {
        let h = abs(session.projectName.hashValue) % 360
        return Color(hue: Double(h) / 360, saturation: 0.5, brightness: 0.85)
    }

    var initials: String {
        let n = session.projectName
        return n.isEmpty ? "?" : String(n.prefix(1).uppercased())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(avatarColor.gradient)
                Text(initials)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .overlay(alignment: .bottomTrailing) {
                if isOpenAsTab {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if agent?.status == .working {
                        LivePulseDot(color: .orange)
                    } else if agent?.status == .waiting {
                        LivePulseDot(color: .yellow)
                    } else if session.isActive {
                        LivePulseDot(color: .orange)
                    }
                    Text(session.displayName)
                        .font(.system(.callout, weight: .semibold))
                        .lineLimit(1)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.pink)
                            .rotationEffect(.degrees(45))
                    }
                    Spacer()
                    if hovering {
                        QuickActions(
                            pinned: pinned,
                            onOpenInApp: { onOpenInApp?() },
                            onOpenInTerminal: { onOpenInTerminal?() },
                            onTogglePin: { onTogglePin?() }
                        )
                        .transition(.opacity)
                    } else {
                        Text(fmtTime(session.mtime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                    if let a = agent, let label = statusLabel(a) {
                        Text(label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(.quaternary.opacity(0.6))
                            )
                    }
                }
                Text(session.firstPrompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}

/// Inline action buttons that fade in on hover — Open in App, Open in
/// Terminal, Pin/Unpin. Replaces the timestamp on hover.
struct QuickActions: View {
    let pinned: Bool
    let onOpenInApp: () -> Void
    let onOpenInTerminal: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            iconButton("play.fill", help: "Open in app", action: onOpenInApp)
            iconButton("rectangle.and.text.magnifyingglass",
                       help: "Open in Terminal.app",
                       action: onOpenInTerminal)
            iconButton(pinned ? "pin.slash.fill" : "pin.fill",
                       help: pinned ? "Unpin" : "Pin to top",
                       action: onTogglePin)
        }
    }

    @ViewBuilder
    private func iconButton(_ symbol: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary.opacity(0.7))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Small pulsing dot used to mark sessions whose transcripts were
/// touched in the last ~minute or that have live hook-driven status —
/// a visual "active right now" indicator.
struct LivePulseDot: View {
    var color: Color = .orange
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.6 : 1.0)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Bottom status bar across the whole window. Shows aggregate counts
/// (working / waiting / total), the hook server indicator, and a quick
/// "install hooks" link — modeled after CliDeck's footer chrome.
struct GlobalStatusBar: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var agentStatus: AgentStatusStore
    @EnvironmentObject var hookServer: HookServer

    private var liveCounts: (working: Int, waiting: Int) {
        var w = 0, n = 0
        let now = Date()
        for (_, state) in agentStatus.byId {
            // Only count fresh hook-driven status (5 min window).
            guard now.timeIntervalSince(state.updated) < 300 else { continue }
            switch state.status {
            case .working: w += 1
            case .waiting: n += 1
            default: break
            }
        }
        return (w, n)
    }

    var body: some View {
        let counts = liveCounts
        HStack(spacing: 14) {
            StatusPill(icon: "tray.full", label: "\(store.sessions.count)", tint: .secondary)
            StatusPill(icon: "bolt.fill", label: "\(counts.working) working", tint: .orange)
            StatusPill(icon: "exclamationmark.bubble.fill",
                       label: "\(counts.waiting) waiting",
                       tint: .yellow,
                       muted: counts.waiting == 0)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(hookServer.running ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(hookServer.running
                     ? "Hook server · :\(hookServer.port)"
                     : "Hook server off")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Install hooks") {
                installHooksWithAlert(port: hookServer.port)
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

struct StatusPill: View {
    let icon: String
    let label: String
    let tint: Color
    var muted: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(muted ? Color.secondary : tint)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(muted ? .secondary : .primary)
        }
    }
}

func statusLabel(_ state: AgentState) -> String? {
    // Stale after 5 minutes of silence — don't keep lying.
    if Date().timeIntervalSince(state.updated) > 300 { return nil }
    switch state.status {
    case .working:
        if let t = state.tool { return t }
        return "working"
    case .waiting: return "needs input"
    case .idle: return nil
    case .unknown: return nil
    }
}
