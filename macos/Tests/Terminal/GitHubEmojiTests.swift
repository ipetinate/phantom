import Foundation
@testable import Ghostty
import Testing

/// Turning GitHub's `:shortcode:` into the emoji it stands for.
struct GitHubEmojiTests {
    // MARK: The two layers

    /// Most of GitHub's list is the Unicode character's own name with
    /// underscores, which is why eighteen hundred entries did not have to be
    /// written down.
    @Test func aShortcodeThatIsAUnicodeNameResolvesWithoutATable() {
        #expect(GitHubEmoji.byUnicodeName("chart_with_downwards_trend") == "\u{1F4C9}")
        #expect(GitHubEmoji.byUnicodeName("hourglass") == "\u{231B}")
    }

    /// And the ones GitHub named for itself come from the table.
    @Test func githubsOwnNamesComeFromTheTable() {
        #expect(GitHubEmoji.emoji(for: "tada") == "\u{1F389}")
        #expect(GitHubEmoji.emoji(for: "+1") == "\u{1F44D}")
        #expect(GitHubEmoji.emoji(for: "white_check_mark") == "\u{2705}")
        #expect(GitHubEmoji.emoji(for: "shipit") == "\u{1F696}")
    }

    /// The table wins where both could answer, so a shortcode GitHub renders
    /// one way is never rendered another.
    @Test func theTableIsPreferredOverTheNameLookup() {
        #expect(GitHubEmoji.emoji(for: "rocket") == GitHubEmoji.named["rocket"])
    }

    // MARK: What must be left alone

    /// The reason the resolution has to be inspected rather than trusted: the
    /// transform answers for *any* Unicode name, so a letter or a space would
    /// come back for text that is not a shortcode at all.
    @Test func aPlainLetterIsNotAnEmoji() {
        #expect(GitHubEmoji.emoji(for: "a") == nil)
        #expect(GitHubEmoji.emoji(for: "space") == nil)
        #expect(GitHubEmoji.emoji(for: "latin_small_letter_a") == nil)
    }

    @Test func nonsenseResolvesToNothing() {
        #expect(GitHubEmoji.emoji(for: "") == nil)
        #expect(GitHubEmoji.emoji(for: "not_a_real_emoji_name_at_all") == nil)
        #expect(GitHubEmoji.emoji(for: "Uppercase") == nil)
        #expect(GitHubEmoji.emoji(for: "with space") == nil)
    }

    // MARK: Rendering a whole string

    @Test func aShortcodeInProseIsReplaced() {
        #expect(GitHubEmoji.render("Ship it :rocket: today")
            == "Ship it \u{1F680} today")
    }

    @Test func severalAreReplacedInOnePass() {
        let rendered = GitHubEmoji.render(":tada: done, :+1:")

        #expect(rendered == "\u{1F389} done, \u{1F44D}")
    }

    /// The case that decides the parser: a timestamp is full of colons and
    /// none of them open a shortcode.
    @Test func aTimestampSurvivesUntouched() {
        #expect(GitHubEmoji.render("at 10:30:15 today") == "at 10:30:15 today")
    }

    /// A URL has a colon followed by slashes, which is not a shortcode and
    /// must not be eaten looking for one.
    @Test func aUrlSurvivesUntouched() {
        let text = "see https://example.com/a:b for more"

        #expect(GitHubEmoji.render(text) == text)
    }

    /// An unknown shortcode is left byte for byte. A preview that dropped one
    /// would be quietly editing somebody's description.
    @Test func anUnknownShortcodeIsLeftAsWritten() {
        #expect(GitHubEmoji.render("uses :internal_thing: here")
            == "uses :internal_thing: here")
    }

    @Test func anUnclosedColonIsLeftAsWritten() {
        #expect(GitHubEmoji.render("ratio 3:1") == "ratio 3:1")
        #expect(GitHubEmoji.render("trailing :") == "trailing :")
    }

    /// The real thing that started this: a pull request body from GitHub.
    @Test func theBodyFromTheScreenshotRenders() {
        let body = ":chart_with_downwards_trend: [Link] :pencil2: [Figma]"

        let rendered = GitHubEmoji.render(body)

        #expect(rendered.contains("\u{1F4C9}"))
        #expect(!rendered.contains(":chart_with_downwards_trend:"))
    }

    @Test func textWithNoColonsIsReturnedUnchanged() {
        let text = "nothing to do here"

        #expect(GitHubEmoji.render(text) == text)
    }

    /// Two shortcodes with nothing between them, which is how a title with a
    /// pair of icons arrives.
    @Test func adjacentShortcodesBothResolve() {
        #expect(GitHubEmoji.render(":fire::zap:") == "\u{1F525}\u{26A1}")
    }
}
