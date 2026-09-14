import AppKit
import SwiftUI

struct AgentOverviewView: View {
    @ObservedObject var center: AgentOverviewCenter
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var now = Date()
    @State private var refusal: String?

    private let clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if center.filtered.isEmpty {
                emptyState
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
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $center.query)
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
        let on = center.stateFilter.contains(state)
        return Button {
            if on { center.stateFilter.remove(state) } else { center.stateFilter.insert(state) }
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
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(center.filtered) { card in
                    AgentSessionCardView(card: card, now: now) { refusal = $0 }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) { OverlayScrollers() }
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

private struct AgentSessionCardView: View {
    let card: AgentSessionCard
    let now: Date
    let report: (String) -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var answer = ""
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !card.previewLines.isEmpty {
                preview
            }
            footer
        }
        .padding(12)
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

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("Answer this agent", text: $answer)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                .onSubmit(send)

            Button("Send", action: send)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Interrupt") {
                if let refusal = AgentSessionActions.interrupt(card.id) {
                    report(refusal.rawValue)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button("Open") {
                if let refusal = AgentSessionActions.jump(to: card.id) {
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
    }
}
