# Codicons — completion list icons

Vendored from [microsoft/vscode-codicons](https://github.com/microsoft/vscode-codicons),
`@vscode/codicons` **0.0.36**. This is the icon font the code editor's
completion list draws its per-kind glyphs with.

## Attribution

> "Codicons" by Microsoft Corporation, licensed under
> [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> Unmodified. See `LICENSE` for the full terms.

**That paragraph is a licence condition, not a courtesy.** The repository's
own `LICENSE` is MIT and covers the code; it does not cover these icons, and
CC BY 4.0 permits redistribution only with the credit, the licence link and a
statement of whether the work was changed. It has to stay somewhere a user of
the built app can reach, which is why this file and `LICENSE` are inside the
resource folder rather than in a developer-facing doc — the whole folder is
copied into `Phantom.app/Contents/Resources/codicons/`, so the credit ships
wherever the glyphs do.

## What was copied

- `codicon.ttf` — upstream's `dist/codicon.ttf`, byte for byte
- `LICENSE` — upstream's CC BY 4.0 text

Upstream's `codicon.css`, `codicon.svg` and `codiconsLibrary.ts` are
deliberately **not** vendored: they map icon names to codepoints for a web
renderer, and nothing here looks an icon up by name. The mapping this app
needs is nineteen codepoints wide and lives in `CodeCompletionItem.Kind`,
where it can be read next to the colour rule it belongs with.

## Updating

Copy `dist/codicon.ttf` and `LICENSE` from a fresh release, bump the version
above, and re-run `CodeCompletionIconTests` — it checks every codepoint the
enum names is still a glyph in the font, which is the failure an update
actually causes. Upstream reassigns codepoints rarely but it has done so.

If a future update patches or subsets the font, the "Unmodified" above stops
being true and CC BY requires it to say so instead.

## Registration

The font is not installed on the user's system, so nothing can find it by
name until it is activated for this process. `CompletionIconFont` does that
with `CTFontManagerRegisterFontsForURL(…, .process, …)` at first use. Its
PostScript name is lowercase `codicon` — `NSFont(name: "Codicon", size:)`
happens to work too, since AppKit's lookup is case-insensitive, but the
lowercase one is what the font actually declares.
