import Foundation

/// One bounded scan of the markup above the caret, answering both halves of
/// tag auto-closing.
///
/// Both halves need the same fact — *which element am I inside, and am I
/// mid-tag* — so this is one scanner rather than two walks that would drift
/// apart. Typing `>` asks whether the tag that just ended wants a closer;
/// typing `</` asks which element is innermost. Both fall out of the same
/// pass.
///
/// **The scan runs forward, never backward.** A backwards walk from the
/// caret to the nearest `<` looks cheaper and gets `<div onClick={() => x}>`
/// wrong: it meets the `>` of the arrow first and gives up, and Prettier
/// formats JSX handlers exactly that way, so the cheap version fails on a
/// large fraction of real React.
///
/// **Names are `NSRange`, never `String`.** Eight kilobytes of dense markup
/// holds hundreds of tags; allocating a string for each of them on every
/// keystroke, only to throw all but one away, is the cost `CodeWordIndex`
/// was written to avoid.
enum CodeTagClose {
    /// How far above the caret the forward scan starts, in UTF-16 units.
    ///
    /// Bounded by what fits on screen: an element opened further above than
    /// this is one whose opening tag the reader cannot see either, and
    /// guessing at it is worse than declining.
    static let scanWindow = 8 * 1024

    /// How far above the caret the SFC region probe looks.
    ///
    /// Four times the scan window, because it answers a different question
    /// and has a different thing to beat: a `<script setup>` block runs
    /// hundreds of lines, and a probe that cannot see over it would report
    /// every caret in a long component as markup.
    static let regionProbeWindow = 32 * 1024

    /// A tag the caret sits inside — opened, not yet terminated.
    struct Pending: Equatable {
        /// Offset of the `<`.
        let start: Int

        /// The element name, which may be empty while it is being typed.
        let name: NSRange

        let isClosing: Bool
    }

    struct Scan: Equatable {
        /// Elements opened and not yet closed, outermost first.
        let openElements: [NSRange]

        let pending: Pending?

        /// The element opened by a tag whose `>` is the last character
        /// before the caret, if that tag opened one.
        ///
        /// The stack alone cannot answer this: after `<div><br>` its top is
        /// `div` either way, and typing the `>` of the `<br>` must not close
        /// anything. Only the scan knows which tag just ended.
        let openedAtCaret: NSRange?

        /// Whether the caret is in markup rather than in a script block, a
        /// stylesheet, or a comment.
        let isInRawText: Bool

        /// The open elements as text.
        ///
        /// For a caller that needs to look at them — a test, a status line —
        /// not for the typing path, which allocates exactly one string and
        /// only when it has decided to insert something.
        func elementNames(in text: NSString) -> [String] {
            openElements.map { text.substring(with: $0) }
        }
    }

    /// The closing tag to insert, or nil to leave the `>` alone.
    ///
    /// `caret` is the offset immediately after a `>` that is **already in
    /// the document**. The scanner reads that `>` out of the text rather
    /// than being told about it, which is the only arrangement where the
    /// caller and the scanner cannot disagree about what was typed.
    static func closingTag(in text: NSString, caret: Int, dialect: CodeTagDialect) -> String? {
        guard caret > 0, caret <= text.length,
              text.character(at: caret - 1) == greaterThan
        else { return nil }

        let result = scan(text, upTo: caret, dialect: dialect)
        guard result.isInRawText, let name = result.openedAtCaret else { return nil }
        return "</\(text.substring(with: name))>"
    }

    /// What to insert after a `/` typed directly behind a `<`, or nil.
    ///
    /// The completion only — `"p>"`, not `"</p>"` — because by the time this
    /// is asked the `</` is already in the document.
    static func closingTagCompletion(in text: NSString, caret: Int, dialect: CodeTagDialect) -> String? {
        guard caret >= 2, caret <= text.length,
              text.character(at: caret - 1) == slash,
              text.character(at: caret - 2) == lessThan
        else { return nil }

        let result = scan(text, upTo: caret, dialect: dialect)
        guard result.isInRawText,
              let pending = result.pending,
              pending.isClosing,
              pending.start == caret - 2,
              pending.name.length == 0,
              let innermost = result.openElements.last
        else { return nil }

        return "\(text.substring(with: innermost))>"
    }

    /// Walks the markup above the caret once.
    ///
    /// Reacts only to `<`. Everything else — quotes in text, braces in text,
    /// the contents of a JSX expression that is not inside a tag — is inert
    /// here, because the states that need tracking only exist inside a tag
    /// body, and tracking them outside one would mean carrying a whole
    /// language's lexer to answer a question about angle brackets.
    static func scan(_ text: NSString, upTo caret: Int, dialect: CodeTagDialect) -> Scan {
        guard dialect.closesTags else {
            return Scan(openElements: [], pending: nil, openedAtCaret: nil, isInRawText: false)
        }

        let end = max(0, min(caret, text.length))
        let start = max(0, end - scanWindow)

        var stack: [NSRange] = []
        var pending: Pending?
        var openedAtCaret: NSRange?
        var isInComment = false

        var index = start
        while index < end {
            guard text.character(at: index) == lessThan else {
                index += 1
                continue
            }

            guard index + 1 < end else {
                pending = Pending(start: index, name: NSRange(location: end, length: 0), isClosing: false)
                index = end
                continue
            }

            let next = text.character(at: index + 1)

            if next == bang {
                if isCommentOpener(at: index, in: text, limit: end) {
                    if let close = indexOfCommentEnd(from: index + 4, in: text, limit: end) {
                        index = close + 3
                    } else {
                        isInComment = true
                        index = end
                    }
                } else if let close = indexOf(greaterThan, from: index + 2, in: text, limit: end) {
                    index = close + 1
                } else {
                    index = end
                }
                continue
            }

            if next == question {
                if let close = indexOf(greaterThan, from: index + 2, in: text, limit: end) {
                    index = close + 1
                } else {
                    index = end
                }
                continue
            }

            if next == slash {
                var cursor = index + 2
                while cursor < end, isNameBody(text.character(at: cursor)) { cursor += 1 }
                let name = NSRange(location: index + 2, length: cursor - (index + 2))

                guard let close = indexOf(greaterThan, from: cursor, in: text, limit: end) else {
                    pending = Pending(start: index, name: name, isClosing: true)
                    index = end
                    continue
                }

                pop(name, from: &stack, in: text, dialect: dialect)
                index = close + 1
                continue
            }

            guard isNameStart(next) else {
                index += 1
                continue
            }

            /// One character of lookbehind, and deliberately no tie to
            /// break. A quote before the `<` means the markup is inside a
            /// string — `const s = "<div>"`, or a template literal holding
            /// HTML — and an identifier before it means a generic, which is
            /// what kills `Array<string>` and `Map<string, Set<number>>`.
            /// The "after the `<`" side contributes nothing extra, because
            /// requiring the body to parse as a tag already handles it:
            /// `a < b` fails on the space and `x <= y` on the `=`.
            if index > 0 {
                let before = text.character(at: index - 1)
                if isQuote(before) {
                    index += 1
                    continue
                }
                if dialect.suppressesTagAfterIdentifier, isIdentifier(before) {
                    index += 1
                    continue
                }
            }

            var cursor = index + 1
            while cursor < end, isNameBody(text.character(at: cursor)) { cursor += 1 }
            let name = NSRange(location: index + 1, length: cursor - (index + 1))

            var braceDepth = 0
            var quote: unichar = 0
            var sawSlash = false
            var terminator: Int?
            var restart: Int?

            while cursor < end {
                let unit = text.character(at: cursor)

                if quote != 0 {
                    if unit == quote { quote = 0 }
                    cursor += 1
                    continue
                }

                if braceDepth > 0 {
                    if unit == openBrace {
                        braceDepth += 1
                    } else if unit == closeBrace {
                        braceDepth -= 1
                    } else if isQuote(unit) {
                        quote = unit
                    }
                    cursor += 1
                    continue
                }

                if isQuote(unit) {
                    quote = unit
                    sawSlash = false
                } else if unit == openBrace {
                    braceDepth = 1
                    sawSlash = false
                } else if unit == greaterThan {
                    terminator = cursor
                    break
                } else if unit == lessThan {
                    restart = cursor
                    break
                } else {
                    sawSlash = unit == slash
                }
                cursor += 1
            }

            /// A `<` inside an unterminated tag body means the first one was
            /// never a tag — half-typed markup, or prose with a stray angle
            /// bracket. Resume at the second one rather than swallow it.
            if let restart {
                index = restart
                continue
            }

            guard let terminator else {
                pending = Pending(start: index, name: name, isClosing: false)
                index = end
                continue
            }

            if !sawSlash, !isVoid(name, in: text, dialect: dialect) {
                stack.append(name)
                if terminator + 1 == end { openedAtCaret = name }
            }
            index = terminator + 1
        }

        /// Not `isInMarkup`, which answers a narrower question: tags can be
        /// closed in a `.tsx` file, whose language is nonetheless JavaScript
        /// and never markup. Only an SFC has a region that rules them out.
        let inClosableRegion = dialect != .sfc || isOutsideScriptAndStyleBlocks(text, caret: end)
        return Scan(
            openElements: stack,
            pending: pending,
            openedAtCaret: openedAtCaret,
            isInRawText: !isInComment && inClosableRegion
        )
    }

    /// Whether the language at the caret is markup.
    ///
    /// Exposed because resolving the language at a caret has callers with
    /// nothing to do with closing tags: an SFC's script block is JavaScript
    /// and its template is HTML, and anything running a per-line pass over
    /// one — highlighting, or suppressing a completion list inside a string
    /// — has to know which before it can be right. Asking `SFCRegions` costs
    /// a whole-document scan per keystroke; this costs four literal searches
    /// over a bounded window.
    ///
    /// **Regions only.** This deliberately says nothing about strings or
    /// comments. A caret inside `<!-- … -->`, or in a quoted attribute
    /// value, is still in markup by this answer — the question is which
    /// language the line is written in, not what it is in the middle of.
    /// `Scan.isInRawText` is the stricter one and folds the comment state
    /// in; a caller wanting that must not reach for this instead.
    ///
    /// `.jsx` is markup-*bearing*, not markup: a `.tsx` file is JavaScript
    /// with tags in its expressions, and every line of it lexes as
    /// JavaScript. Only `.html` and an SFC's template answer yes — which is
    /// why this is not the same predicate as `Scan.isInRawText`, which is
    /// true in a `.tsx` file because tags can be closed there.
    static func isInMarkup(_ text: NSString, caret: Int, dialect: CodeTagDialect) -> Bool {
        switch dialect {
        case .none, .jsx: return false
        case .html: return true
        case .sfc: return isOutsideScriptAndStyleBlocks(text, caret: caret)
        }
    }

    /// Whether the caret sits outside every top-level `<script>` and
    /// `<style>` block.
    ///
    /// Deliberately not `SFCRegions`: that compiles three regular
    /// expressions and scans the whole document three times with no cache,
    /// which is affordable once per colouring pass and not once per
    /// keystroke. And it answers a question this does not ask — a keystroke
    /// does not need the document partitioned, only "am I in markup here",
    /// which four literal backwards searches answer at C speed.
    ///
    /// Leans on the same convention `SFCRegions` documents: an SFC's blocks
    /// start at column zero, and a nested `<template #slot>` is indented
    /// because it is inside something. Testing for `<script`/`<style`
    /// rather than for `<template` is what makes this right for Svelte too,
    /// where the markup is the top level and has no wrapper of its own.
    ///
    /// The window only ever looks *behind* the caret, and that is by design
    /// rather than by luck: it is what makes a `.svelte` file work whichever
    /// order its blocks come in. Markup written *above* the `<script>` block
    /// sits above every marker, finds nothing, and is reported as markup —
    /// correctly, because a block beginning below the caret cannot contain
    /// it. A forward-looking or whole-document partition would have to
    /// reason about which block the caret falls between; this never does.
    private static func isOutsideScriptAndStyleBlocks(_ text: NSString, caret: Int) -> Bool {
        let start = max(0, caret - regionProbeWindow)
        let window = NSRange(location: start, length: caret - start)
        guard window.length > 0 else { return true }

        for block in ["script", "style"] {
            let opened = lastBlockMarker("<\(block)", in: text, within: window)
            let closed = lastBlockMarker("</\(block)>", in: text, within: window)
            if opened > closed { return false }
        }
        return true
    }

    /// The last offset in `window` where `marker` starts a line, or -1.
    private static func lastBlockMarker(_ marker: String, in text: NSString, within window: NSRange) -> Int {
        let found = text.range(of: "\n" + marker, options: [.backwards, .literal], range: window)
        if found.location != NSNotFound { return found.location + 1 }

        let length = (marker as NSString).length
        guard window.location == 0, window.length >= length,
              text.compare(marker, options: [.literal], range: NSRange(location: 0, length: length)) == .orderedSame
        else { return -1 }
        return 0
    }

    /// Elements HTML parses as void: no closing tag exists for them, so
    /// offering one writes markup the parser will reject.
    ///
    /// The thirteen the current HTML spec lists, plus `param` — removed from
    /// the spec but still parsed as void for legacy content, so `</param>`
    /// would be wrong in exactly the files that still contain it.
    ///
    /// `command` and `keygen` are deliberately absent. Both were dropped
    /// before either shipped widely, and both are plausible names for
    /// somebody's element — a lowercase `<command>` in JSX is an unknown DOM
    /// element, which React closes like any other, so listing it here would
    /// break a working case to fix one that does not occur.
    static let voidElements = [
        "area", "base", "br", "col", "embed", "hr", "img",
        "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Names packed into an integer, six ASCII characters at a time.
    ///
    /// Six covers the longest name on the list, and comparing integers keeps
    /// the per-tag void check free of the `String` this scanner exists to
    /// avoid allocating.
    private static let voidKeys: Set<UInt64> = Set(
        voidElements.compactMap { name in
            var key: UInt64 = 0
            for unit in name.utf16 { key = (key << 8) | UInt64(unit) }
            return key
        }
    )

    private static func isVoid(_ name: NSRange, in text: NSString, dialect: CodeTagDialect) -> Bool {
        guard (2...6).contains(name.length) else { return false }

        var key: UInt64 = 0
        for offset in 0..<name.length {
            let unit = text.character(at: name.location + offset)
            switch unit {
            case 0x41...0x5A:
                /// A capital means "component" wherever components exist, so
                /// `<Br>` gets its closing tag while `<br>` does not. In HTML
                /// there is no such distinction and `<BR>` is the void one.
                if dialect.treatsCapitalisedNamesAsComponents { return false }
                key = (key << 8) | UInt64(unit + 0x20)
            case 0x61...0x7A:
                key = (key << 8) | UInt64(unit)
            default:
                return false
            }
        }
        return voidKeys.contains(key)
    }

    /// Closes the innermost matching element, and everything left open
    /// inside it.
    ///
    /// A closing tag with nothing to match is dropped rather than allowed to
    /// pop whatever happens to be on top — a bounded window starts wherever
    /// it starts, so its first few closing tags routinely have no opener in
    /// view, and popping on those would corrupt a stack that was correct.
    private static func pop(
        _ name: NSRange,
        from stack: inout [NSRange],
        in text: NSString,
        dialect: CodeTagDialect
    ) {
        guard name.length > 0 else { return }
        guard let index = stack.lastIndex(where: {
            equalNames($0, name, in: text, ignoringCase: dialect.matchesNamesCaseInsensitively)
        }) else { return }
        stack.removeSubrange(index...)
    }

    private static func equalNames(
        _ first: NSRange,
        _ second: NSRange,
        in text: NSString,
        ignoringCase: Bool
    ) -> Bool {
        guard first.length == second.length else { return false }
        for offset in 0..<first.length {
            var left = text.character(at: first.location + offset)
            var right = text.character(at: second.location + offset)
            if ignoringCase {
                left = lowered(left)
                right = lowered(right)
            }
            guard left == right else { return false }
        }
        return true
    }

    private static func lowered(_ unit: unichar) -> unichar {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }

    private static func indexOf(_ unit: unichar, from: Int, in text: NSString, limit: Int) -> Int? {
        var index = from
        while index < limit {
            if text.character(at: index) == unit { return index }
            index += 1
        }
        return nil
    }

    private static func isCommentOpener(at index: Int, in text: NSString, limit: Int) -> Bool {
        index + 4 <= limit
            && text.character(at: index + 2) == hyphen
            && text.character(at: index + 3) == hyphen
    }

    private static func indexOfCommentEnd(from: Int, in text: NSString, limit: Int) -> Int? {
        var index = from
        while index + 3 <= limit {
            if text.character(at: index) == hyphen,
               text.character(at: index + 1) == hyphen,
               text.character(at: index + 2) == greaterThan {
                return index
            }
            index += 1
        }
        return nil
    }

    /// ASCII on purpose, for the reason `CodeWordIndex` states about its own
    /// character class: every element name and every identifier anyone puts
    /// in front of a `<` is ASCII, and Unicode-aware classification here
    /// would be paid for on every character of every keystroke to gain names
    /// nobody types.
    private static func isNameStart(_ unit: unichar) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F
    }

    /// Hyphens for custom elements, dots for `<Foo.Bar>`, colons for the
    /// namespaces that turn up in SVG and in Vue templates.
    private static func isNameBody(_ unit: unichar) -> Bool {
        isNameStart(unit)
            || (0x30...0x39).contains(unit)
            || unit == hyphen || unit == 0x2E || unit == 0x3A
    }

    private static func isIdentifier(_ unit: unichar) -> Bool {
        isNameStart(unit) || (0x30...0x39).contains(unit) || unit == 0x24
    }

    private static func isQuote(_ unit: unichar) -> Bool {
        unit == 0x22 || unit == 0x27 || unit == 0x60
    }

    private static let lessThan: unichar = 0x3C
    private static let greaterThan: unichar = 0x3E
    private static let slash: unichar = 0x2F
    private static let bang: unichar = 0x21
    private static let question: unichar = 0x3F
    private static let hyphen: unichar = 0x2D
    private static let openBrace: unichar = 0x7B
    private static let closeBrace: unichar = 0x7D
}
