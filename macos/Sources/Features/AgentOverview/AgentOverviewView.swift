import AppKit
import SwiftUI

struct AgentOverviewView: View {
    @ObservedObject var center: AgentOverviewCenter
    var compact: Bool = false
    var paneBackground: Color? = nil
    var onReopen: (AgentSessionCard, UUID?) -> Void = { _, _ in }
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var now = Date()
    @State private var refusal: String?
    @State private var reopenCard: AgentSessionCard?
    @ObservedObject private var groups: SidebarGroupStore = .shared
    @State private var query = ""
    @State private var stateFilter: Set<AgentTabState> = []

    private let clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var accent: Color { palette.accent ?? .accentColor }

    /// The sidebar is a live-process view; the main pane is the complete
    /// session history. Search and state chips belong to each view, not to
    /// the shared center, so filtering one never changes the other.
    private var displayedCards: [AgentSessionCard] {
        let source = compact
            ? center.cards.filter { $0.liveness != .ended }
            : center.cards
        return AgentSessionFilter.apply(source, query: query, states: stateFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if displayedCards.isEmpty {
                emptyState
            } else if compact {
                compactList
            } else {
                list
            }
        }
        .onAppear {
            center.beginObserving()
            center.noteVisible(Set(center.cards.map(\.id)))
        }
        .onDisappear { center.endObserving() }
        .onReceive(clock) { now = $0 }
        .onChange(of: center.cards.map(\.id)) { ids in
            center.noteVisible(Set(ids))
        }
        .alert(
            refusal ?? "",
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
        ) {
            Button("OK") { refusal = nil }
        }
        .confirmationDialog(
            "Reopen session",
            isPresented: Binding(
                get: { reopenCard != nil },
                set: { if !$0 { reopenCard = nil } }),
            presenting: reopenCard
        ) { card in
            Button("New standalone terminal") {
                onReopen(card, nil)
                reopenCard = nil
            }
            ForEach(groups.groups) { group in
                Button("Open in (group.name)") {
                    onReopen(card, group.id)
                    reopenCard = nil
                }
            }
            Button("Cancel", role: .cancel) { reopenCard = nil }
        } message: { card in
            Text("Choose where to reopen (card.agent.displayName)'s session.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paneBackground ?? .clear)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
            Spacer(minLength: 8)
            ForEach(AgentOverviewView.filterStates, id: \.self) { state in
                stateChip(state)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let filterStates: [AgentTabState] = [.awaiting, .working, .failed, .done]

    private func stateChip(_ state: AgentTabState) -> some View {
        let on = stateFilter.contains(state)
        return Button {
            if on {
                stateFilter.remove(state)
            } else if compact {
                // The live sidebar is a quick status switcher: one status at
                // a time keeps it readable and prevents combinations such as
                // "Working + Done" from looking like a second mode.
                stateFilter = [state]
            } else {
                stateFilter.insert(state)
            }
        } label: {
            Text(AgentOverviewView.label(for: state))
                .font(palette.font(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(on ? accent.opacity(0.22) : Color.primary.opacity(0.06)))
                .overlay(
                    Capsule().strokeBorder(
                        on ? accent.opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(displayedCards) { card in
                    AgentSessionCardView(card: card, now: now, onReopen: { reopenCard = $0 }) {
                        refusal = $0
                    }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) { OverlayScrollers() }
    }

    private var compactList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(displayedCards) { card in
                    AgentSessionListRow(card: card, now: now) { refusal = $0 }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(center.cards.isEmpty ? "No agent sessions" : "Nothing matches")
                .font(palette.font(size: 13, weight: .semibold))
            if center.cards.isEmpty {
                Text("A session shows up here once its agent's hooks are installed. "
                    + "Settings › Agents installs them in one click.")
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func label(for state: AgentTabState) -> String {
        switch state {
        case .working: return "Working"
        case .awaiting: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Failed"
        case .compacting: return "Compacting"
        case .denied: return "Denied"
        case .ended: return "Ended"
        }
    }
}

private struct AgentSessionListRow: View {
    let card: AgentSessionCard
    let now: Date
    let report: (String) -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        Button {
            if let refusal = AgentSessionActions.jump(to: card.id) {
                report(refusal.rawValue)
            }
        } label: {
            HStack(spacing: 8) {
                AgentIconView(card.agent.descriptor, size: 13, tint: .brand)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(palette.font(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(card.agent.displayName)
                        .font(palette.font(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let state = card.state {
                    Text(AgentOverviewView.label(for: state))
                        .font(palette.font(size: 9, weight: .medium))
                        .foregroundStyle(stateColor(state))
                }
                if let elapsed = elapsedLabel {
                    Text(elapsed)
                        .font(palette.font(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045)))
        }
        .buttonStyle(.plain)
    }

    private var elapsedLabel: String? {
        guard let at = card.lastEventAt else { return nil }
        let seconds = Int(now.timeIntervalSince(at))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "(seconds / 60)m" }
        return "(seconds / 3600)h"
    }

    private func stateColor(_ state: AgentTabState) -> Color {
        switch state {
        case .working, .compacting: return accent
        case .awaiting: return palette.yellow ?? .orange
        case .failed, .denied: return palette.danger ?? .red
        case .done: return palette.success ?? .green
        default: return .secondary
        }
    }
}

private struct AgentSessionCardView: View {
    let card: AgentSessionCard
    let now: Date
    let onReopen: (AgentSessionCard) -> Void
    let report: (String) -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var answer = ""
    @State private var isHovered = false
    @State private var isSending = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !card.previewLines.isEmpty {
                preview
            } else {
                missingSummary
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            card.wantsAttention ? accent.opacity(0.45) : Color.primary.opacity(0.1),
                            lineWidth: 1))
        )
        .onHover { isHovered = $0 }
        .onChange(of: card.state) { state in
            if state == .working || state == .compacting {
                isSending = true
            } else if state == .awaiting || state == .done || state == .failed {
                isSending = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentIconView(card.agent.descriptor, size: 14, tint: .brand)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.agent.displayName)
                        .font(palette.font(size: 12, weight: .semibold))
                    stateChip
                    if card.liveness == .ended && card.state != nil {
                        Text(verbatim: "process gone")
                            .font(palette.font(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(card.title)
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let sessionID = card.sessionID {
                    HStack(spacing: 3) {
                        Text(String(sessionID.prefix(12)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sessionID, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy session hash")
                    }
                }
                if let place = placeLine {
                    Text(place)
                        .font(palette.font(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let elapsed = elapsedLabel {
                Text(elapsed)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateChip: some View {
        Group {
            if let state = card.state {
                Text(AgentOverviewView.label(for: state))
                    .font(palette.font(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(chipColor.opacity(0.2)))
                    .foregroundStyle(chipColor)
            }
        }
    }

    private var chipColor: Color {
        switch card.state {
        case .awaiting: return palette.yellow ?? .orange
        case .failed, .denied: return palette.danger ?? .red
        case .working, .compacting: return accent
        case .done: return palette.success ?? .green
        default: return .secondary
        }
    }

    private var placeLine: String? {
        let parts = [card.groupName, card.worktreeBranch, card.pwd.map(abbreviate)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private var elapsedLabel: String? {
        guard let at = card.lastEventAt else { return nil }
        let seconds = Int(now.timeIntervalSince(at))
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(card.previewLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.18)))
    }

    private var missingSummary: some View {
        Text("No output snapshot recorded for this session")
            .font(palette.font(size: 10))
            .foregroundStyle(.tertiary)
            .italic()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if card.liveness == .running {
                TextField("Answer this agent", text: $answer)
                    .textFieldStyle(.plain)
                    .font(palette.font(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    .onSubmit(send)

                Button {
                    if isSending {
                        stop()
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: isSending ? "stop.fill" : "paperplane.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(isSending ? "Stop agent" : "Send message")
                .disabled(!isSending && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("Terminal closed")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
            }

            Button(card.liveness == .ended ? "Reopen" : "Open") {
                if card.liveness == .ended {
                    onReopen(card)
                } else if let refusal = AgentSessionActions.jump(to: card.id) {
                    report(refusal.rawValue)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fontWeight(.semibold)
            .foregroundStyle(accent)
        }
    }

    private func send() {
        if let refusal = AgentSessionActions.reply(answer, to: card.id) {
            report(refusal.rawValue)
            return
        }
        answer = ""
        isSending = true
    }

    private func stop() {
        if let refusal = AgentSessionActions.interrupt(card.id) {
            report(refusal.rawValue)
        }
        isSending = false
    }
}
