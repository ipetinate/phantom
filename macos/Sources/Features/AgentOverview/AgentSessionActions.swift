import AppKit
import Foundation

@MainActor
enum AgentSessionActions {
    enum Refusal: String {
        case gone = "That terminal is no longer open."
        case notLive = "That session has ended, so there is nothing listening."
        case atShell = "That terminal is back at a shell prompt."
        case interruptRebound = "Ctrl-C is bound to something else in your config."
    }

    static func jump(to id: UUID) -> Refusal? {
        guard let (controller, surface) = AgentOverviewCenter.controller(for: id) else {
            return .gone
        }

        if let window = surface.window,
           let manager = controller.sidebarTabManager,
           let model = manager.models.first(where: { $0.window === window }) {
            manager.select(model)
        }

        controller.focusSurface(surface)
        return nil
    }

    static func reply(_ text: String, to id: UUID) -> Refusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let surface = AgentOverviewCenter.surface(for: id) else { return .gone }
        guard TabStateCenter.shared.records[id]?.liveAgent != nil else { return .notLive }
        guard let model = surface.surfaceModel else { return .gone }
        guard !TerminalIdleCheck.isIdle(foregroundPID: model.foregroundPID) else { return .atShell }

        model.sendText(trimmed)
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
        rereadPreview(id)
        return nil
    }

    static func interrupt(_ id: UUID) -> Refusal? {
        guard let surface = AgentOverviewCenter.surface(for: id) else { return .gone }
        guard TabStateCenter.shared.records[id]?.liveAgent != nil else { return .notLive }
        guard let model = surface.surfaceModel else { return .gone }

        let mods: Ghostty.Input.Mods = [.ctrl]
        let press = Ghostty.Input.KeyEvent(
            synthesizing: .c,
            action: .press,
            mods: mods,
            translationMods: model.keyTranslationMods(mods))
        let release = Ghostty.Input.KeyEvent(
            synthesizing: .c,
            action: .release,
            mods: mods,
            translationMods: model.keyTranslationMods(mods))

        model.sendKeyEvent(press)
        model.sendKeyEvent(release)
        rereadPreview(id)
        return nil
    }

    private static func rereadPreview(_ id: UUID) {
        for delay in [0.25, 1.0] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                AgentOverviewCenter.shared.refreshPreview(for: id)
            }
        }
    }
}
