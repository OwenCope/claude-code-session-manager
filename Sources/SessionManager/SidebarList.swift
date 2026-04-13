import SwiftUI

/// CliDeck-style sidebar: each session is a Messages-style row with avatar,
/// name, last activity, and a preview line. Clicking a row selects it
/// (and double-click opens an embedded terminal tab).
struct SidebarSessionList: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TerminalTabs
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
                    SidebarRow(session: s, isOpenAsTab: tabs.open.contains(where: { $0.id == s.id }))
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
                HStack {
                    Text(session.displayName)
                        .font(.system(.callout, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(fmtTime(session.mtime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(session.projectName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                Text(session.firstPrompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }
}
