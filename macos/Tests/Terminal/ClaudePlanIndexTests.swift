import Foundation
@testable import Ghostty
import Testing

/// Matching a plan to the terminals it belongs to.
///
/// The plan file says nothing about where it came from, so the link runs
/// through the session transcript's directory name — which encodes a working
/// directory *lossily*. Every test here exists because the obvious approach,
/// decoding that name back into a path, cannot work.
struct ClaudePlanEncodingTests {
    @Test func slashesAndDotsBothBecomeDashes() {
        #expect(
            ClaudePlanIndex.encode("/Users/isac.petinate/Projects")
                == "-Users-isac-petinate-Projects"
        )
    }

    /// The ambiguity, stated: two different paths encode to the same name.
    /// This is why nothing decodes — the answer would be a guess.
    @Test func theEncodingIsNotReversible() {
        let withDot = ClaudePlanIndex.encode("/Users/isac.petinate/Projects")
        let withSlash = ClaudePlanIndex.encode("/Users/isac/petinate/Projects")
        #expect(withDot == withSlash)
    }

    /// And why comparing encoded forms is still sound: the map is
    /// character-for-character, so it preserves prefixes.
    @Test func aDirectoryInsideAProjectMatchesIt() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects")
        #expect(ClaudePlanIndex.project(project, contains: "/Users/x/Projects"))
        #expect(ClaudePlanIndex.project(project, contains: "/Users/x/Projects/Tools/phantom"))
    }

    /// The separator is required, or a project would claim its siblings.
    @Test func aSiblingWithASharedPrefixDoesNotMatch() {
        let project = ClaudePlanIndex.encode("/Users/x/Tools")
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x/ToolsX"))
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x/ToolsX/inner"))
    }

    @Test func aDirectoryOutsideTheProjectDoesNotMatch() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects")
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x/Documents"))
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x"))
    }

    @Test func anEmptyPathMatchesNothing() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects")
        #expect(!ClaudePlanIndex.project(project, contains: ""))
    }

    /// A path with a dot in a directory name still matches its project, which
    /// is the case that made decoding tempting in the first place.
    @Test func aDottedDirectoryNameStillMatches() {
        let project = ClaudePlanIndex.encode("/Users/isac.petinate/Projects")
        #expect(
            ClaudePlanIndex.project(project, contains: "/Users/isac.petinate/Projects/Tools")
        )
    }
}

/// Reading the tail of a transcript.
struct ClaudePlanTranscriptTests {
    private func write(_ contents: String) -> String {
        let path = NSTemporaryDirectory() + "phantom-transcript-\(UUID().uuidString).jsonl"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func theNeedleIsFoundInASmallFile() {
        let path = write("{\"text\":\"plan at fizzy-frolicking-haven.md\"}")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(ClaudePlanIndex.tail(of: path, contains: "fizzy-frolicking-haven"))
        #expect(!ClaudePlanIndex.tail(of: path, contains: "some-other-plan"))
    }

    /// Only the tail is read, because these files reach tens of megabytes.
    /// A mention near the *end* is what a plan written during the session
    /// looks like.
    @Test func aMentionNearTheEndIsFound() {
        let padding = String(repeating: "x", count: 200_000)
        let path = write(padding + "\nmentions moonlit-popcorn\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(ClaudePlanIndex.tail(of: path, contains: "moonlit-popcorn"))
    }

    @Test func aMissingFileIsNotAMatchAndDoesNotCrash() {
        #expect(!ClaudePlanIndex.tail(of: "/nowhere/\(UUID()).jsonl", contains: "anything"))
    }

    @Test func anEmptyFileIsNotAMatch() {
        let path = write("")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!ClaudePlanIndex.tail(of: path, contains: "anything"))
    }
}

/// The title shown on the tag's tooltip.
struct ClaudePlanTitleTests {
    private func plan(_ contents: String) -> (ClaudePlanIndex.Plan, String) {
        let path = NSTemporaryDirectory() + "phantom-plan-\(UUID().uuidString).md"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return (ClaudePlanIndex.Plan(path: path, modified: Date(timeIntervalSince1970: 0)), path)
    }

    /// The file names are random slugs, so the heading is the only part a
    /// reader recognises.
    @Test func theFirstHeadingIsTheTitle() {
        let (plan, path) = plan("# Painel direito com abas\n\nsome text")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(plan.title == "Painel direito com abas")
    }

    @Test func aPlanWithNoHeadingFallsBackToItsName() {
        let (plan, path) = plan("no heading here")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(plan.title.hasPrefix("phantom-plan-"))
        #expect(!plan.title.hasSuffix(".md"))
    }

    @Test func aDeeperHeadingIsNotTheTitle() {
        let (plan, path) = plan("## Context\n\n# Real Title\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(plan.title == "Real Title")
    }
}

/// Getting rid of a plan: the tag a reader has hidden, and the record hiding
/// leaves behind.
///
/// Nothing here reads or writes `~/.claude`. This suite is hosted in the app
/// and runs as the developer, so a test that deleted a plan would delete one
/// of theirs. The cases that need a directory build their own under
/// `NSTemporaryDirectory` and take it away again.
struct ClaudePlanHideTests {
    private func withStore(_ body: (ClaudePlanHideStore) throws -> Void) throws {
        let name = "ClaudePlanHideTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        try body(ClaudePlanHideStore(defaults: defaults))
    }

    private func plan(_ path: String) -> ClaudePlanIndex.Plan {
        ClaudePlanIndex.Plan(path: path, modified: Date(timeIntervalSince1970: 10_000))
    }

    /// The report this came from: a plan nobody is working on any more, on a
    /// row that never stops showing it.
    @Test func aHiddenPlanIsNotOffered() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects/phantom")
        let leftover = plan("/Users/x/.claude/plans/mossy-parrot.md")

        #expect(
            ClaudePlanIndex.plan(
                forTerminalAt: "/Users/x/Projects/phantom",
                in: [project: leftover],
                hidden: []
            ) == leftover
        )
        #expect(
            ClaudePlanIndex.plan(
                forTerminalAt: "/Users/x/Projects/phantom",
                in: [project: leftover],
                hidden: [leftover.path]
            ) == nil
        )
    }

    /// Hiding one project's plan says nothing about another's, so a tag the
    /// parent repository still has does not come down with it.
    @Test func hidingADeeperPlanLeavesTheParentsAlone() {
        let parent = ClaudePlanIndex.encode("/Users/x/Projects/phantom")
        let deeper = ClaudePlanIndex.encode("/Users/x/Projects/phantom/macos")
        let kept = plan("/Users/x/.claude/plans/kept.md")
        let hidden = plan("/Users/x/.claude/plans/hidden.md")

        #expect(
            ClaudePlanIndex.plan(
                forTerminalAt: "/Users/x/Projects/phantom/macos/Sources",
                in: [parent: kept, deeper: hidden],
                hidden: [hidden.path]
            ) == kept
        )
    }

    @Test func hidingTheSamePlanTwiceKeepsOneRecord() throws {
        try withStore { store in
            store.hide("/plans/a.md")
            store.hide("/plans/a.md")

            #expect(store.hidden == ["/plans/a.md"])
        }
    }

    /// The records are the one part of this that could grow forever, so one
    /// whose file has left the directory goes the next time it is read.
    @Test func aRecordForAPlanThatLeftTheDirectoryIsPruned() throws {
        let directory = NSTemporaryDirectory() + "phantom-plans-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let kept = (directory as NSString).appendingPathComponent("kept.md")
        let gone = (directory as NSString).appendingPathComponent("gone.md")
        try "# Kept".write(toFile: kept, atomically: true, encoding: .utf8)
        try "# Gone".write(toFile: gone, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: gone)

        let onDisk = Set(
            try FileManager.default.contentsOfDirectory(atPath: directory)
                .map { (directory as NSString).appendingPathComponent($0) }
        )

        try withStore { store in
            store.hide(kept)
            store.hide(gone)
            store.prune(existing: onDisk)

            #expect(store.hidden == [kept])
        }
    }

    /// A read that came back with nothing is either an empty directory or one
    /// that could not be read, and the two are indistinguishable — so it
    /// prunes nothing rather than clearing every record the reader has.
    @Test func aReadThatFoundNoPlansPrunesNothing() throws {
        try withStore { store in
            store.hide("/plans/a.md")
            store.prune(existing: [])

            #expect(store.hidden == ["/plans/a.md"])
        }
    }

    /// Deleting the file drops the record with it. A plan's name is a slug out
    /// of a pool, so the path can come back — and a record left behind would
    /// hide a plan the reader has never seen.
    @Test func deletingAPlanDropsItsHideRecord() throws {
        try withStore { store in
            store.hide("/plans/a.md")
            store.hide("/plans/b.md")
            store.forget("/plans/a.md")

            #expect(store.hidden == ["/plans/b.md"])
        }
    }

    /// The key is named once and read from there, so a second spelling cannot
    /// appear in a view and quietly write somewhere else.
    @Test func theKeyIsNamedOnce() throws {
        #expect(ClaudePlanHideStore.defaultsKey == "SidebarHiddenClaudePlans")

        let name = "ClaudePlanHideTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        ClaudePlanHideStore(defaults: defaults).hide("/plans/a.md")

        #expect(
            defaults.stringArray(forKey: ClaudePlanHideStore.defaultsKey) == ["/plans/a.md"]
        )
    }
}
