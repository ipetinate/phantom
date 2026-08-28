import Foundation
@testable import Ghostty
import Testing

/// Which server a `completionItem/resolve` goes back to.
///
/// A `.vue` file's completion list is two servers' answers concatenated, and
/// an item only means something to the process that made it. Measured
/// against a live pair: handing `typescript-language-server`'s item to
/// `@vue/language-server` answers
/// `-32603 Cannot read properties of undefined (reading '1')`, so the import
/// a `<script setup>` auto-import promised was never written.
struct LSPCompletionOriginTests {
    private func item(_ label: String, origin: String? = nil) -> LSPCompletion {
        var parsed = LSPCompletion(["label": .string(label)])!
        parsed.origin = origin
        return parsed
    }

    /// A parsed item claims nothing until a list attributes it.
    @Test func aFreshlyParsedItemHasNoOrigin() {
        #expect(item("WDrawer").origin == nil)
    }

    @Test func attributionMarksEveryItemAndKeepsTheRest() throws {
        let list = LSPCompletionList(
            items: [item("WDrawer"), item("WSelect")],
            isIncomplete: true
        ).attributed(to: "vue-language-server")

        #expect(list.items.allSatisfy { $0.origin == "vue-language-server" })
        #expect(list.items.map(\.label) == ["WDrawer", "WSelect"])
        #expect(list.isIncomplete)
    }

    /// Attribution survives the flattening, which is the point: `merged` is
    /// where the answers stop being told apart by position.
    @Test func attributionSurvivesTheMerge() throws {
        let template = LSPCompletionList(items: [item("WDrawer")]).attributed(to: "vue-language-server")
        let script = LSPCompletionList(items: [item("useRefundAnalysisForm")])
            .attributed(to: "typescript-language-server")

        let merged = LSPCompletionList.merged([template, script])
        #expect(merged.items.count == 2)
        #expect(merged.items[0].origin == "vue-language-server")
        #expect(merged.items[1].origin == "typescript-language-server")
    }

    /// The item's own server answers it, even though it is not the file's
    /// primary — this is the whole fix.
    @Test func anItemGoesBackToTheServerThatMadeIt() {
        let commands = ["vue-language-server", "typescript-language-server"]
        let script = item("WDrawer", origin: "typescript-language-server")

        #expect(LSPCenter.resolvingCommand(for: script, among: commands) == "typescript-language-server")
    }

    @Test func aTemplateItemStillGoesToTheVueServer() {
        let commands = ["vue-language-server", "typescript-language-server"]
        let template = item("WDrawer", origin: "vue-language-server")

        #expect(LSPCenter.resolvingCommand(for: template, among: commands) == "vue-language-server")
    }

    /// A server that has exited between the list and the resolve falls back
    /// to the primary rather than refusing. Asking somebody beats asking
    /// nobody: the worst case is the answer the unrouted version always gave.
    @Test func anOriginThatIsNoLongerRunningFallsBackToThePrimary() {
        let stale = item("WDrawer", origin: "typescript-language-server")

        #expect(LSPCenter.resolvingCommand(for: stale, among: ["vue-language-server"]) == "vue-language-server")
    }

    /// An unattributed item — one parsed anywhere that does not attribute —
    /// behaves exactly as it did before.
    @Test func anUnattributedItemGoesToThePrimary() {
        #expect(
            LSPCenter.resolvingCommand(for: item("map"), among: ["typescript-language-server"])
                == "typescript-language-server"
        )
    }

    @Test func noServerAtAllHasNoAnswer() {
        #expect(LSPCenter.resolvingCommand(for: item("map", origin: "gopls"), among: []) == nil)
    }
}
