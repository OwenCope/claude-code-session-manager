import SwiftUI

/// CliDeck-style sidebar: each session is a Messages-style row with avatar,
/// name, last activity, and a preview line. Clicking a row selects it
/// (and double-click opens an embedded terminal tab).
struct SidebarSessionList: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TerminalTabs
    @EnvironmentObject var agentStatus: AgentStatusStore
    @Binding var selection: Set<String>

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
                ForEach(store.filtered) { s in
                    SidebarRow(session: s,
                               isOpenAsTab: tabs.open.contains(where: { $0.id == s.id }),
                               agent: agentStatus.state(for: s.id))
                        .tag(s.id)
                        .contextMenu {
                            Button("Open in App") { tabs.openOrFocus(s) }
                            Button("Open in Terminal.app") { resumeInTerminal(s) }
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

struct SidebarRow: View {
    let session: Session
    let isOpenAsTab: Bool
    let agent: AgentState?

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
                    Spacer()
                    Text(fmtTime(session.mtime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

/// Compact footer under the sidebar showing whether the hook server is
/// running and which port it's on. Tapping the "Install hooks" link runs
/// the same installer as the menu item.
struct HookServerFooter: View {
    @EnvironmentObject var hookServer: HookServer

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(hookServer.running ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(hookServer.running
                 ? "Hook server · :\(hookServer.port)"
                 : "Hook server off")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Install hooks") {
                installHooksWithAlert(port: hookServer.port)
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
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
