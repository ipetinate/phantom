import AppKit
@testable import Ghostty
import Testing

/// The completion list's icons: which glyph each kind draws, which colour it
/// borrows, and the affordance that says a row has documentation behind it.
///
/// Every test here is a pure function over values. Not one presents a panel,
/// for the reason written at the top of `CodeCompletionPanelTests`: the test
/// host has no running event loop, so anything that reaches `orderFront` hangs
/// the call forever and takes the whole suite down with it.
///
/// **What this file cannot check is that the font is in the bundle**, since the
/// test bundle is not the app's. It checks the half that is a decision — the
/// codepoints — and the other half is proved by
/// `CompletionIconFont.font(ofSize:)` returning nil, which the panel treats as
/// "draw SF Symbols" rather than as an error.
struct CodeCompletionIconTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Concrete colours rather than `CodeTheme.fallback`, whose `.textColor` is
    /// a dynamic catalog colour with no component to read outside a drawing
    /// context — the same reason `CodeCompletionPanelTests` builds its own.
    private var theme: CodeTheme {
        CodeTheme(
            foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
            background: NSColor(calibratedWhite: 0.1, alpha: 1),
            tokens: [
                .function: NSColor(calibratedRed: 0.3, green: 0.6, blue: 1, alpha: 1),
                .keyword: NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.9, alpha: 1),
                .attribute: NSColor(calibratedRed: 0.9, green: 0.7, blue: 0.2, alpha: 1),
                .string: NSColor(calibratedRed: 0.4, green: 0.8, blue: 0.4, alpha: 1),
                .type: NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.8, alpha: 1),
            ],
            lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
            currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
            currentLineBackground: nil
        )
    }

    private func item(_ label: String, kind: CodeCompletionItem.Kind) -> CodeCompletionItem {
        CodeCompletionItem(kind: kind, label: label)
    }

    // MARK: - Codepoints

    /// Codicons live entirely in the Unicode private use area, and a codepoint
    /// outside it is a typo that draws a *different* character rather than
    /// nothing — a stray CJK ideograph in the icon column, at whatever width
    /// the fallback font gives it.
    @Test func everyKindNamesACodepointInThePrivateUseArea() {
        for kind in CodeCompletionItem.Kind.allCases {
            let value = kind.codicon.value
            #expect(
                value >= 0xE000 && value <= 0xF8FF,
                "\(kind.rawValue) maps to U+\(String(value, radix: 16, uppercase: true)), which is not a private use codepoint"
            )
        }
    }

    /// The six kinds added for markup and for the type family, checked against
    /// `codicon.csv` by hand. A wrong codepoint here still draws *something* —
    /// the neighbouring icon — which is the failure mode a screenshot does not
    /// catch and this does.
    @Test func theNewKindsDrawTheGlyphTheyWereMappedTo() {
        #expect(CodeCompletionItem.Kind.tag.codicon == "\u{EA66}")
        #expect(CodeCompletionItem.Kind.attribute.codicon == "\u{EA92}")
        #expect(CodeCompletionItem.Kind.event.codicon == "\u{EA86}")
        #expect(CodeCompletionItem.Kind.attributeValue.codicon == "\u{EB8D}")
        #expect(CodeCompletionItem.Kind.interface.codicon == "\u{EB61}")
        #expect(CodeCompletionItem.Kind.structure.codicon == "\u{EA91}")
    }

    /// The kinds that were already here keep VS Code's assignment, which is the
    /// only reason to ship somebody else's font: the glyphs are recognised
    /// before they are read.
    @Test func theExistingKindsKeepUpstreamsAssignment() {
        #expect(CodeCompletionItem.Kind.method.codicon == "\u{EA8C}")
        #expect(CodeCompletionItem.Kind.keyword.codicon == "\u{EB62}")
        #expect(CodeCompletionItem.Kind.property.codicon == "\u{EB65}")
        #expect(CodeCompletionItem.Kind.type.codicon == "\u{EB5B}")
        #expect(CodeCompletionItem.Kind.enumCase.codicon == "\u{EB5E}")
        #expect(CodeCompletionItem.Kind.snippet.codicon == "\u{EB66}")
    }

    /// The enum's own standard, enforced: a case exists because it changes the
    /// icon **or** the colour, so two kinds sharing both are one kind with two
    /// names and a bridge that has to guess between them.
    ///
    /// `function` and `method` are the single exception, and they are upstream's
    /// — VS Code draws both with `symbol-method` in the same colour. They keep
    /// separate SF Symbols, which is checked below, so the fallback path still
    /// tells them apart.
    @Test func noTwoKindsRenderIdenticallyExceptTheOnePairUpstreamMerges() {
        let kinds = CodeCompletionItem.Kind.allCases
        var collisions: [String] = []

        for (offset, kind) in kinds.enumerated() {
            for other in kinds.dropFirst(offset + 1)
            where kind.codicon == other.codicon && kind.tokenKind == other.tokenKind {
                collisions.append("\(kind.rawValue)/\(other.rawValue)")
            }
        }

        #expect(collisions == ["function/method"], "unexpected identical renderings: \(collisions)")
    }

    /// The fallback has to stay complete and stay distinct, because it is what
    /// draws when the bundled font fails to register — and a fallback that
    /// silently merges two kinds is worse than one that fails loudly.
    @Test func everyKindKeepsItsOwnSymbolFallback() {
        let names = CodeCompletionItem.Kind.allCases.map(\.symbolName)

        #expect(Set(names).count == names.count, "two kinds share an SF Symbol: \(names)")
    }

    /// The same check `CodeCompletionItemTests` makes for the fourteen original
    /// kinds, extended to the six new ones: a name this OS has no symbol for
    /// returns nil from AppKit and leaves the column blank, with no crash and
    /// no warning.
    @Test func theNewKindsNameSymbolsThisSystemHas() {
        let added: [CodeCompletionItem.Kind] = [
            .tag, .attribute, .event, .attributeValue, .interface, .structure,
        ]

        for kind in added {
            #expect(
                NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil,
                "\(kind.rawValue) names \(kind.symbolName), which this system has no symbol for"
            )
        }
    }

    // MARK: - Colour

    /// The rule is *what the highlighter would paint this identifier if it were
    /// already in the file*, and for markup that was read off
    /// `SyntaxRules.rules(for: .html)` rather than chosen.
    ///
    /// The tag is the one that looks wrong and is right: the HTML rule that
    /// matches `</?[A-Za-z][A-Za-z0-9-]*` is the **keyword** one, so `<div` is
    /// painted in the keyword colour in the file and the row that inserts it is
    /// painted the same.
    @Test func theMarkupKindsBorrowTheColourTheHtmlRulesPaintThem() {
        #expect(CodeCompletionItem.Kind.tag.tokenKind == .keyword)
        #expect(CodeCompletionItem.Kind.attribute.tokenKind == .attribute)
        #expect(CodeCompletionItem.Kind.event.tokenKind == .attribute)
        #expect(CodeCompletionItem.Kind.attributeValue.tokenKind == .string)
    }

    /// Both are things you implement against or instantiate, and the
    /// highlighter has one colour for all of them — the distinction they carry
    /// is in the glyph.
    @Test func interfaceAndStructAreTypesLikeAClassIs() {
        #expect(CodeCompletionItem.Kind.interface.tokenKind == .type)
        #expect(CodeCompletionItem.Kind.structure.tokenKind == .type)
        #expect(CodeCompletionItem.Kind.type.tokenKind == .type)
    }

    /// The label takes the icon's colour, not the reader's plain text colour.
    ///
    /// This is the assertion to delete when the label goes back to plain — the
    /// one line that changes is `labelColor(for:theme:)`, and this test is what
    /// tells you the change landed rather than half-landed.
    @Test func theLabelIsPaintedInTheKindsOwnColour() {
        let function = CodeCompletionPanel.labelColor(for: item("connect", kind: .function), theme: theme)
        let tag = CodeCompletionPanel.labelColor(for: item("div", kind: .tag), theme: theme)

        #expect(function == theme.color(for: .function))
        #expect(tag == theme.color(for: .keyword))
        #expect(function != theme.foreground, "a label the colour of plain text is the design this replaced")
    }

    /// A kind the highlighter has no opinion about comes out in the plain
    /// colour, which is what a local variable looks like in the file too — so
    /// colouring the label does not invent a distinction the code does not have.
    @Test func aPlainKindsLabelStaysPlain() {
        let variable = CodeCompletionPanel.labelColor(for: item("count", kind: .variable), theme: theme)

        #expect(variable == theme.color(for: .plain))
    }

    /// The colour has to reach the drawn string, not just the function that
    /// decides it — the matched characters are re-attributed on top and it
    /// would be easy to leave that path on the old foreground.
    @Test func theDrawnLabelCarriesTheKindsColourThroughTheEmphasis() {
        let text = CodeCompletionPanel.labelText(
            for: item("connect", kind: .function),
            query: "con",
            theme: theme,
            font: font
        )

        let matched = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let rest = text.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor

        #expect(matched?.redComponent == theme.color(for: .function).redComponent)
        #expect(rest?.redComponent == theme.color(for: .function).redComponent)
    }

    // MARK: - The info affordance

    /// One row at a time, and only when there is something behind it. A column
    /// of info glyphs is a second icon column competing for the same glance,
    /// and a glyph over nothing is a button whose answer is "nothing".
    @Test func onlyTheSelectedRowWithDocumentationShowsTheGlyph() {
        #expect(CodeCompletionPanel.showsInfo(isSelected: true, hasDocumentation: true))
        #expect(!CodeCompletionPanel.showsInfo(isSelected: true, hasDocumentation: false))
        #expect(!CodeCompletionPanel.showsInfo(isSelected: false, hasDocumentation: true))
        #expect(!CodeCompletionPanel.showsInfo(isSelected: false, hasDocumentation: false))
    }

    /// The glyph sits at the trailing edge, inside the row's own inset, and
    /// centred on the line the label sits on.
    @Test func theInfoGlyphSitsAtTheTrailingEdgeOfTheRow() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 20)
        let rect = CodeCompletionPanel.infoRect(in: bounds, side: 14, inset: 8)

        #expect(rect.maxX == CGFloat(292))
        #expect(rect.width == CGFloat(14))
        #expect(rect.height == CGFloat(14))
        #expect(rect.midY == CGFloat(10))
        #expect(bounds.contains(rect), "the affordance has to be inside the row it belongs to")
    }

    /// The glyph is dimmer than the row it sits on: it is an offer, and at full
    /// strength it would be the brightest thing on the one row whose label is
    /// being read.
    @Test func theInfoGlyphIsDimmerThanTheRow() {
        let glyph = CodeCompletionPanel.infoGlyph(theme: theme, font: font)
        let color = glyph.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(color != nil)
        #expect((color?.alphaComponent ?? 1) < CGFloat(1))
        #expect(glyph.string == "\u{EA74}")
    }

    // MARK: - Glyph rendering

    /// The icon's colour is applied where the glyph is built, because the one
    /// thing worse than an SF Symbol in the icon column is the right Codicon in
    /// the wrong colour.
    @Test func theGlyphIsBuiltInTheKindsColour() {
        let glyph = CodeCompletionPanel.iconGlyph(
            for: .function,
            color: theme.color(for: .function),
            font: font
        )

        let color = glyph.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(glyph.string == String(CodeCompletionItem.Kind.function.codicon))
        #expect(color?.redComponent == theme.color(for: .function).redComponent)
    }

    /// The host supplies the font once and never hears about a font change, so
    /// the list is the one that has to resize it — otherwise the icons stay at
    /// whatever size the host happened to ask for while the rows around them
    /// grow.
    @Test func theIconFontFollowsTheEditorsSize() {
        let supplied = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        #expect(CodeCompletionPanel.scaled(supplied, to: 18)?.pointSize == CGFloat(18))
        #expect(CodeCompletionPanel.scaled(supplied, to: 13)?.pointSize == CGFloat(13))
    }

    /// No font is the SF Symbol path, and it has to stay reachable through
    /// every helper rather than becoming a crash in one of them.
    @Test func noIconFontStaysNoIconFont() {
        #expect(CodeCompletionPanel.scaled(nil, to: 18) == nil)
    }

    /// Centred rather than left-aligned: a Codicon's advance width has nothing
    /// to do with the square an SF Symbol filled, so left-aligning the two
    /// paths would move the label depending on whether a font registered.
    @Test func theGlyphIsCentredInItsColumn() {
        let glyph = CodeCompletionPanel.iconGlyph(for: .tag, color: .white, font: font)
        let paragraph = glyph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        #expect(paragraph?.alignment == .center)
    }
}
