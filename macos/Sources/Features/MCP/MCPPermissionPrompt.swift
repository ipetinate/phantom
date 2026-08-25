import AppKit
import Combine
import Foundation

/// The question the reader answers, and the only place in the app that asks
/// it.
///
/// **Why one object rather than one per window.** `MCPPermissionStore` is a
/// singleton, so a window that observed `pending` itself would put a copy of
/// the same question on every open window — one sheet per window, all of them
/// carrying the one `answer` closure that may be called once. The reader would
/// answer whichever they reached first and the rest would be left standing over
/// a `pending` that is already nil, each still able to call an answer that has
/// been given. So no window knows this exists. One app-level object subscribes
/// and attaches the sheet to whichever window is key when the agent asks, which
/// is the window the reader is looking at and therefore the only one they could
/// answer from.
///
/// **Why `NSAlert` rather than SwiftUI's `confirmationDialog`.**
/// `BaseTerminalController.confirmClose` already made this choice and named the
/// bug (Ghostty #560): a `confirmationDialog` can be closed with Cmd-W, and
/// when it is, SwiftUI updates no binding and calls nothing back. Elsewhere in
/// this app that is cosmetic. Here it is a deadlock — `pending` would stay set
/// with nothing on screen, and the store refuses every later question while one
/// is pending, so a single Cmd-W would silently deny the agent everything for
/// the rest of the session with no way for the reader to find out why.
///
/// **Why it is not a form.** Six buttons is a dialog nobody reads, so the two
/// dimensions are carried by different controls: the duration is which button
/// the reader presses, and the reach is a segmented control above them. One
/// choice to make, one button to press.
@MainActor
final class MCPPermissionPrompt {
    static let shared = MCPPermissionPrompt()

    private var subscription: AnyCancellable?

    /// The sheet on screen, and the bookkeeping that keeps it answered exactly
    /// once. Nil the moment an answer is on its way, so the dismissal that
    /// follows cannot answer a second time.
    private var showing: NSAlert?

    private init() {}

    /// Begins watching the store. Called once, at launch.
    func start() {
        guard subscription == nil else { return }

        subscription = MCPPermissionStore.shared.$pending
            .sink { [weak self] pending in
                guard let self else { return }
                if let pending {
                    self.present(pending)
                } else {
                    self.withdraw()
                }
            }
    }

    // MARK: What the sheet offers

    /// The scopes this question can honestly offer, narrow to wide.
    ///
    /// A `tab` grant is measured against the surface the request names and a
    /// `group` grant against the group, so offering either without one to
    /// anchor it would write a grant that `MCPPermission.isAllowed` can never
    /// match — the reader would press "Always Allow" and be asked again on the
    /// next call, forever. `all` needs no anchor and is always offered.
    static func scopes(for request: MCPPermission.Request) -> [MCPPermission.Scope] {
        var offered: [MCPPermission.Scope] = []
        if request.surface != nil { offered.append(.tab) }
        if request.group != nil { offered.append(.group) }
        offered.append(.all)
        return offered
    }

    /// Reach, in the reader's words. "All Terminals" rather than "all", because
    /// the segment has to say what it costs without a legend.
    static func label(for scope: MCPPermission.Scope) -> String {
        switch scope {
        case .tab: return "This Tab"
        case .group: return "This Group"
        case .all: return "All Terminals"
        }
    }

    enum Answer: Equatable {
        case refuse
        case grant(always: Bool)
    }

    /// What a dismissal meant.
    ///
    /// Everything that is not one of the two allow buttons refuses, and the
    /// `default` arm is load-bearing rather than tidy: a sheet whose parent
    /// window closed ends with a response none of these cases names, and a
    /// question that ends without an answer has to end as a refusal. The store
    /// asks one question at a time, so an unanswered one would otherwise turn
    /// every later call into a silent denial.
    static func answer(for response: NSApplication.ModalResponse) -> Answer {
        switch response {
        case .alertFirstButtonReturn: return .grant(always: false)
        case .alertSecondButtonReturn: return .grant(always: true)
        default: return .refuse
        }
    }

    /// What the reader is told they are risking, under the question itself.
    static func informative(for capability: MCPPermission.Capability) -> String {
        let stakes: String
        switch capability {
        case .read:
            stakes = "Scrollback can hold keys, tokens and production output."
        case .run:
            stakes = "Commands run in an idle terminal, as if you had typed them."
        }

        return "\(stakes) Choose how far this reaches; it starts at the narrowest. "
            + "\u{201C}Always Allow\u{201D} is remembered until you revoke it in Settings, under MCP. "
            + "\u{201C}Allow Once\u{201D} lasts only as long as this connection."
    }

    // MARK: Presenting

    private func present(_ pending: MCPPermissionStore.Pending) {
        guard showing == nil else { return }

        let scopes = Self.scopes(for: pending.request)
        let picker = Self.picker(for: scopes)
        let alert = Self.alert(for: pending, picker: picker)
        showing = alert

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.showing === alert else { return }
            self.showing = nil

            /// Ordered out by hand, for the reason `BaseTerminalController`
            /// gives: an alert left in place costs the window its focus under
            /// Stage Manager (Ghostty #8336).
            alert.window.orderOut(nil)

            switch Self.answer(for: response) {
            case .refuse:
                pending.answer(nil, false)
            case .grant(let always):
                let index = min(max(picker.selectedSegment, 0), scopes.count - 1)
                pending.answer(scopes[index], always)
            }
        }

        guard let host = Self.host else {
            /// No window to hang a sheet on — every one closed, or the app is
            /// running with none open yet. Hopped off this turn first, because
            /// the store sets `pending` from inside the tool call that raised
            /// it, and a modal run loop started there would run inside that
            /// call.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                finish(alert.runModal())
            }
            return
        }

        alert.beginSheetModal(for: host, completionHandler: finish)
    }

    /// Takes the sheet down when the question went away without this object
    /// answering it.
    ///
    /// Only an answer clears `pending` today, and an answer has already emptied
    /// `showing` by the time this runs, so in practice this returns
    /// immediately. It exists because the one state this design cannot survive
    /// is a sheet outliving its question: the store holds one question at a
    /// time, and a stale sheet over a fresh `pending` would be answered for the
    /// wrong request.
    private func withdraw() {
        guard let alert = showing else { return }
        showing = nil

        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else {
            alert.window.orderOut(nil)
        }
    }

    /// The window the sheet hangs on: the one the reader is looking at.
    ///
    /// Skips a window that already has a sheet, because a second one queues
    /// behind the first and the reader would answer this after answering
    /// something unrelated — by which time the agent has long since been told
    /// no by the cooldown.
    private static var host: NSWindow? {
        var candidates: [NSWindow] = []
        if let key = NSApp.keyWindow { candidates.append(key) }
        if let main = NSApp.mainWindow { candidates.append(main) }
        candidates += NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }

        return candidates.first { $0.attachedSheet == nil && $0.sheetParent == nil }
    }

    private static func picker(for scopes: [MCPPermission.Scope]) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: scopes.map(label),
            trackingMode: .selectOne,
            target: nil,
            action: nil)

        /// The narrowest, always. This is what makes the widest button on the
        /// sheet safe: "Always Allow" pressed without touching the picker
        /// grants one tab for good, not every terminal for good. Reaching "All
        /// Terminals" costs a separate, deliberate click.
        control.selectedSegment = 0
        control.segmentDistribution = .fillEqually
        control.sizeToFit()
        control.setFrameSize(NSSize(
            width: max(300, control.frame.width),
            height: control.frame.height))
        return control
    }

    /// Builds the sheet, and with it the rule that no single key grants
    /// anything.
    ///
    /// AppKit gives Return to the first button it is handed, which here would
    /// be "Allow Once", so that key equivalent is taken away again. Escape goes
    /// to "Don't Allow". Return is then handed to the same button through the
    /// window's default cell, which is also what draws it as the default one —
    /// the same arrangement `SidebarView`'s group-delete confirmation makes,
    /// and for the same reason: the destructive reading must not be what a
    /// distracted Return produces.
    ///
    /// The default cell is the one part of this AppKit may decline to honour
    /// for an alert it owns. That is survivable by construction: if it does not
    /// take, Return does nothing at all. No arrangement of these three buttons
    /// makes Return grant something.
    private static func alert(
        for pending: MCPPermissionStore.Pending,
        picker: NSView
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = MCPPermission.question(
            client: pending.client,
            capability: pending.request.capability,
            tabTitle: pending.tabTitle)
        alert.informativeText = informative(for: pending.request.capability)
        alert.accessoryView = picker

        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Don't Allow")

        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = alert.buttons[2].cell as? NSButtonCell

        return alert
    }
}
