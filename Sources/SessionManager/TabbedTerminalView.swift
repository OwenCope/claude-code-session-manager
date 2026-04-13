import SwiftUI

/// Tab strip + active terminal pane. Empty state when no tabs are open.
struct TabbedTerminalView: View {
    @EnvironmentObject var tabs: TerminalTabs
    @EnvironmentObject var store: SessionStore

    var activeSession: Session? {
        guard let id = tabs.active else { return nil }
        return tabs.open.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.open.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabs.open) { s in
                            TabChip(
                                session: s,
                                isActive: tabs.active == s.id,
                                onSelect: { tabs.active = s.id },
                                onClose: { tabs.close(s.id) }
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(.thinMaterial)
                Divider()
            }

            if let s = activeSession {
                TerminalPaneView(session: s)
                    .id(s.id)
            } else {
                EmptyTerminalState()
            }
        }
    }
}

struct TabChip: View {
    let session: Session
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
            Text(session.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if hovering || isActive {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .frame(maxWidth: 220)
    }
}

struct EmptyTerminalState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("No session open")
                .font(.title3.weight(.semibold))
            Text("Pick a session in the sidebar and press ⏎ — it'll resume right here in the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.02))
    }
}
