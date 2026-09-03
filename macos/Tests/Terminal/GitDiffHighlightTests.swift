import Foundation
@testable import Ghostty
import Testing

/// The token colouring a diff document carries for its two columns.
///
/// Every line of a diff used to be drawn in one foreground colour, which made
/// a screen of additions a screen of undifferentiated green. These tests pin
/// the three rules that changed it: which language each column is lexed as,
/// where a token lands once it is cut back up per line, and what a file the
/// highlighter cannot lex falls back to.
struct GitDiffHighlightTests {
    private func document(_ output: String) throws -> GitDiffDocument {
        GitDiffDocument(file: try #require(GitDiffParser.parse(unified: output).first))
    }

    private func drawn(_ span: GitDiffHighlight.Span, of line: GitDiffLine?) throws -> String {
        (try #require(line).displayText as NSString).substring(with: span.range)
    }

    @Test func theLanguageComesFromTheNameAndNotThePath() {
        #expect(GitDiffHighlight.language(forPath: "macos/Sources/App.swift") == .swift)
        #expect(GitDiffHighlight.language(forPath: "src/api/client.ts") == .javascript)

        /// The table for a name that carries its own language is matched
        /// whole, so a path has to be cut down to its last component before
        /// it can answer — `services/api/go.mod` is in none of them.
        #expect(GitDiffHighlight.language(forPath: "services/api/go.mod") == .go)

        #expect(GitDiffHighlight.language(forPath: "assets/data.bin") == .plain)
    }

    /// Both columns of one row, each lexed on its own text: the old line ends
    /// in a number and the new one in a string, and neither answer leaks
    /// across.
    @Test func eachColumnIsColouredByItsOwnTokens() throws {
        let document = try document(#"""
        diff --git a/src/total.ts b/src/total.ts
        --- a/src/total.ts
        +++ b/src/total.ts
        @@ -1 +1 @@
        -const total = 1
        +const total = "two"
        """#)

        let row = try #require(document.rows.first)
        let left = document.highlight.spans(forRow: row.id, side: .left)
        let right = document.highlight.spans(forRow: row.id, side: .right)

        #expect(left.map(\.kind) == [.keyword, .number])
        #expect(right.map(\.kind) == [.keyword, .string])
        #expect(try right.map { try drawn($0, of: row.right) } == ["const", #""two""#])
    }

    /// The offsets are into the line the pane draws, which is the reason the
    /// colouring is worked out on `displayText`: measured on `text`, every
    /// span of a CRLF file would sit one character short of the glyph it
    /// belongs to and the last of them would run past the end.
    @Test func aCarriageReturnIsOutsideEverySpan() throws {
        let document = try document(
            "diff --git a/x.ts b/x.ts\n--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-const a = 1\r\n+const a = 2\r\n")

        let row = try #require(document.rows.first)
        let spans = document.highlight.spans(forRow: row.id, side: .right)
        let drawnLength = (try #require(row.right).displayText as NSString).length

        #expect(spans.map(\.kind) == [.keyword, .number])
        #expect(spans.allSatisfy { NSMaxRange($0.range) <= drawnLength })
        #expect(try drawn(try #require(spans.last), of: row.right) == "2")
    }

    /// Why a side is lexed whole rather than a line at a time: none of these
    /// three lines is a comment on its own, and a per-line pass would colour
    /// the opener and leave the body plain.
    @Test func aBlockCommentKeepsItsColourOnEveryLineItSpans() throws {
        let document = try document(#"""
        diff --git a/lib.ts b/lib.ts
        --- a/lib.ts
        +++ b/lib.ts
        @@ -1,2 +1,5 @@
         export const one = 1
        +/*
        + * why this exists
        + */
         export const two = 2
        """#)

        let added = document.rows.filter { $0.left == nil && $0.right != nil }
        #expect(added.count == 3)

        for row in added {
            #expect(document.highlight.spans(forRow: row.id, side: .right).map(\.kind) == [.comment])
        }
        #expect(try added.map {
            try drawn(try #require(document.highlight.spans(forRow: $0.id, side: .right).first), of: $0.right)
        } == ["/*", " * why this exists", " */"])

        /// The rows are filler on the left, and the two sides are indexed
        /// apart — the old column's spans belong to the lines it actually
        /// has.
        for row in added {
            #expect(document.highlight.spans(forRow: row.id, side: .left).isEmpty)
        }
    }

    /// A rename can carry a file into another language, and the old column is
    /// still the old file. Lexed as one language, one of these two lines
    /// would lose its comment: `#` means nothing to JavaScript and `//`
    /// means nothing to Python.
    @Test func aRenameLexesEachColumnByTheNameThatColumnHad() throws {
        let document = try document(#"""
        diff --git a/tool.py b/tool.js
        similarity index 60%
        rename from tool.py
        rename to tool.js
        --- a/tool.py
        +++ b/tool.js
        @@ -1 +1 @@
        -# the old comment
        +// the new comment
        """#)

        let row = try #require(document.rows.first)
        #expect(document.highlight.spans(forRow: row.id, side: .left).map(\.kind) == [.comment])
        #expect(document.highlight.spans(forRow: row.id, side: .right).map(\.kind) == [.comment])
    }

    /// A single-file component is lexed by the block a line is in, which the
    /// diff can only answer when it carries the block's own tags — a hunk
    /// deep inside a `<script>` has nothing to say where it is, and draws
    /// plain.
    @Test func aComponentsScriptBlockIsColouredAsScript() throws {
        let document = try document(#"""
        diff --git a/App.vue b/App.vue
        --- a/App.vue
        +++ b/App.vue
        @@ -1,3 +1,3 @@
         <script setup lang="ts">
        -const total = 1
        +const total = 2
         </script>
        """#)

        let row = try #require(document.rows.first { $0.left?.kind == .removed })
        #expect(document.highlight.spans(forRow: row.id, side: .right).map(\.kind) == [.keyword, .number])
    }

    /// The fallback, and the reason it is an empty list rather than an empty
    /// line: a file this build cannot lex draws exactly as it did before
    /// there was any colouring.
    @Test func aLanguageWithNoRulesLeavesEveryLinePlain() throws {
        let document = try document(#"""
        diff --git a/data.bin b/data.bin
        --- a/data.bin
        +++ b/data.bin
        @@ -1 +1 @@
        -const total = 1
        +const total = 2
        """#)

        let row = try #require(document.rows.first)
        #expect(document.highlight.spans(forRow: row.id, side: .left).isEmpty)
        #expect(document.highlight.spans(forRow: row.id, side: .right).isEmpty)
    }

    /// The budget degrades the way the inline-edit budget does: the lines
    /// past it keep their numbers, their signs and their band, and only lose
    /// their colours.
    @Test func pastTheBudgetTheColouringStopsRatherThanTheDiff() throws {
        let line = "const value = 1"
        let count = (GitDiffHighlight.textBudget / (line.count + 1)) * 2

        var output = "diff --git a/big.ts b/big.ts\n--- a/big.ts\n+++ b/big.ts\n@@ -0,0 +1,\(count) @@\n"
        output += String(repeating: "+\(line)\n", count: count)
        let document = try document(output)

        #expect(document.rows.count == count)
        #expect(!document.highlight.spans(forRow: 0, side: .right).isEmpty)
        #expect(document.highlight.spans(forRow: count - 1, side: .right).isEmpty)
    }
}

/// Colouring a fragment of a document made of blocks.
///
/// `SFCRegions` finds a `.vue` file's blocks by their tags, so a hunk from
/// the middle of one has nothing to say which block it is in: it matched no
/// region and lexed to nothing, and the card drew flat text until the reader
/// expanded the file far enough to pull a tag into the fragment. The whole
/// version of the file answers instead, mapped on by line number.
struct GitDiffWholeFileHighlightTests {
    /// Sixteen lines, and the change is on the fifth — four lines below the
    /// `<script>` tag and one above `</script>`, so a two-line hunk carries
    /// neither.
    private let component = """
    <script setup lang="ts">
    import { ref } from 'vue';

    const searchTerm = ref('');
    const total = 1;
    </script>

    <template>
      <div class="filters">{{ total }}</div>
    </template>

    <style scoped lang="scss">
    .filters {
      display: flex;
    }
    </style>
    """

    private var updated: String {
        component.replacingOccurrences(of: "const total = 1;", with: "const total = 2;")
    }

    private let fragment = """
    diff --git a/App.vue b/App.vue
    --- a/App.vue
    +++ b/App.vue
    @@ -4,2 +4,2 @@
     const searchTerm = ref('');
    -const total = 1;
    +const total = 2;
    """

    private func document(_ output: String, source: GitDiffSource = .none) throws -> GitDiffDocument {
        GitDiffDocument(
            file: try #require(GitDiffParser.parse(unified: output).first),
            source: source)
    }

    private func drawn(_ span: GitDiffHighlight.Span, of line: GitDiffLine?) throws -> String {
        (try #require(line).displayText as NSString).substring(with: span.range)
    }

    /// **The defect, pinned.** The fragment carries no block tag, so the diff
    /// alone cannot say it is script.
    @Test func theFragmentHasNoColourFromTheDiffAlone() throws {
        let document = try document(fragment)
        let row = try #require(document.rows.first { $0.left?.kind == .removed })

        #expect(document.highlight.spans(forRow: row.id, side: .left).isEmpty)
        #expect(document.highlight.spans(forRow: row.id, side: .right).isEmpty)
    }

    @Test func theWholeFileColoursTheSameFragment() throws {
        let document = try document(
            fragment,
            source: GitDiffSource(old: component, new: updated))
        let row = try #require(document.rows.first { $0.left?.kind == .removed })

        let left = document.highlight.spans(forRow: row.id, side: .left)
        let right = document.highlight.spans(forRow: row.id, side: .right)

        #expect(left.map(\.kind) == [.keyword, .number])
        #expect(right.map(\.kind) == [.keyword, .number])
        #expect(try left.map { try drawn($0, of: row.left) } == ["const", "1"])
        #expect(try right.map { try drawn($0, of: row.right) } == ["const", "2"])
    }

    /// The context lines too — they are most of a fragment, and they are the
    /// lines the reader has to read the change against.
    @Test func theContextLinesAreColouredAsWell() throws {
        let document = try document(
            fragment,
            source: GitDiffSource(old: component, new: updated))
        let row = try #require(document.rows.first { $0.left?.kind == .context })

        let kinds = document.highlight.spans(forRow: row.id, side: .right).map(\.kind)
        #expect(kinds.contains(.keyword))
        #expect(kinds.contains(.function))
    }

    /// One side read and the other not is an ordinary state — a rename whose
    /// old name is gone, a base that could not be resolved — and the side
    /// with nothing falls back rather than taking the other's answer.
    @Test func oneSideWithNoVersionLeavesTheOtherAlone() throws {
        let document = try document(fragment, source: GitDiffSource(old: nil, new: updated))
        let row = try #require(document.rows.first { $0.left?.kind == .removed })

        #expect(document.highlight.spans(forRow: row.id, side: .left).isEmpty)
        #expect(document.highlight.spans(forRow: row.id, side: .right).map(\.kind) == [.keyword, .number])
    }

    /// A version that is not the one the diff was taken against maps onto
    /// nothing, and the diff's own text answers instead. Colouring a line
    /// from the wrong file is the failure this refuses.
    @Test func aVersionThatDoesNotMatchIsDiscarded() throws {
        let document = try document(
            fragment,
            source: GitDiffSource(old: "something else\n", new: "something else\n"))
        let row = try #require(document.rows.first { $0.left?.kind == .removed })

        #expect(document.highlight.spans(forRow: row.id, side: .right).isEmpty)
    }

    /// The fallback, with a version in hand: a file this build cannot lex
    /// draws plain whatever else is known about it.
    @Test func aLanguageWithNoRulesIsStillPlain() throws {
        let output = """
        diff --git a/data.bin b/data.bin
        --- a/data.bin
        +++ b/data.bin
        @@ -4,2 +4,2 @@
         const searchTerm = ref('');
        -const total = 1;
        +const total = 2;
        """
        let document = try document(output, source: GitDiffSource(old: component, new: updated))
        let row = try #require(document.rows.first { $0.left?.kind == .removed })

        #expect(document.highlight.spans(forRow: row.id, side: .left).isEmpty)
        #expect(document.highlight.spans(forRow: row.id, side: .right).isEmpty)
    }

    /// A tag inside the fragment is not a second answer: the whole file is
    /// still the one being lexed, and the tag keeps the tokens it has in the
    /// editor.
    @Test func aTagInsideTheFragmentIsStillTakenApart() throws {
        let output = """
        diff --git a/App.vue b/App.vue
        --- a/App.vue
        +++ b/App.vue
        @@ -1,2 +1,2 @@
         <script setup lang="ts">
        -import { ref } from 'vue';
        +import { ref, computed } from 'vue';
        """
        let source = component.replacingOccurrences(
            of: "import { ref } from 'vue';",
            with: "import { ref, computed } from 'vue';")
        let document = try document(output, source: GitDiffSource(old: component, new: source))
        let row = try #require(document.rows.first { $0.left?.kind == .context })

        let spans = document.highlight.spans(forRow: row.id, side: .right)
        #expect(spans.map(\.kind) == [.punctuation, .keyword, .attribute, .attribute, .punctuation, .string, .punctuation])
        #expect(try spans.map { try drawn($0, of: row.right) }
            == ["<", "script", "setup", "lang", "=", "\"ts\"", ">"])
    }
}

/// Which diffs pay for reading both versions of their file.
struct GitDiffWholeFileNeedTests {
    private func file(_ output: String) throws -> GitFileDiff {
        try #require(GitDiffParser.parse(unified: output).first)
    }

    private func diff(_ path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -4,1 +4,1 @@
        -const total = 1;
        +const total = 2;
        """
    }

    @Test func aChangedComponentAsksForIt() throws {
        #expect(GitDiffHighlight.needsWholeFile(try file(diff("App.vue"))))
        #expect(GitDiffHighlight.needsWholeFile(try file(diff("page.html"))))
    }

    /// A language that is one language needs nothing but the hunks: its rules
    /// do not depend on where in the file a line sits.
    @Test func aLanguageThatIsOnlyItselfDoesNot() throws {
        #expect(!GitDiffHighlight.needsWholeFile(try file(diff("src/total.ts"))))
        #expect(!GitDiffHighlight.needsWholeFile(try file(diff("assets/data.bin"))))
    }

    /// A file arriving or leaving already has every line of itself in the
    /// hunks, and a branch of new work is mostly made of those.
    @Test func aWholeFileArrivingOrLeavingDoesNot() throws {
        let added = """
        diff --git a/App.vue b/App.vue
        new file mode 100644
        --- /dev/null
        +++ b/App.vue
        @@ -0,0 +1,1 @@
        +const total = 1;
        """
        let deleted = """
        diff --git a/App.vue b/App.vue
        deleted file mode 100644
        --- a/App.vue
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -const total = 1;
        """
        #expect(!GitDiffHighlight.needsWholeFile(try file(added)))
        #expect(!GitDiffHighlight.needsWholeFile(try file(deleted)))
    }
}

/// Which two versions each side of a diff compares, named for `git show`.
struct GitDiffRevisionTests {
    /// The new side of a working-tree diff is the file on disk. Git prints a
    /// hash for it in the diff header and that hash names no object — so nil
    /// here means "read the file", not "give up".
    @Test func aWorkingTreeDiffComparesTheIndexAgainstTheDisk() {
        let revisions = GitDiffLoader.revisions(for: .unstaged, in: "/")
        #expect(revisions?.old == ":0")
        #expect(revisions?.new == nil)
    }

    @Test func aStagedDiffComparesTheCommitAgainstTheIndex() {
        let revisions = GitDiffLoader.revisions(for: .staged, in: "/")
        #expect(revisions?.old == "HEAD")
        #expect(revisions?.new == ":0")
    }
}
