# Phantom features

What Phantom adds to Ghostty, and where each piece stands. Current version:
`0.22.0-beta`. Latest release: `v0.21.0`.

The suffix says how finished a version is: `-beta` while the product is usable
but still taking fixes, and nothing at all once it is stable. There are no
`-dev` builds; work in progress lives on a branch.

The user-facing documentation is at <https://phantom.nertec.com.br/>.

## What comes from Ghostty

The terminal itself is Ghostty's, untouched — that is the reason this is a fork
and not a new app.

| Layer | Origin |
|---|---|
| Terminal emulation, renderer, splits, themes, fonts | Ghostty |
| Quick terminal, command palette | Ghostty |
| AppleScript, App Intents, Sparkle updates | Ghostty |
| Secure input, clipboard confirmation, global keybinds | Ghostty |
| Everything in the table below | Phantom |

## Phantom features

`Shipped` is in a published release. `Unreleased` is built and on the open PR.
`Unverified` is built and covered by tests but never opened in a window.
`Planned` has not started.

| Area | Feature | State | Version |
|---|---|---|---|
| Tabs | Grouped tabs, with an icon and colour per group | Shipped | v0.2.0 |
| Tabs | Sidebar panes: terminals, files, git | Shipped | v0.2.0 |
| Tabs | Dev-server port detected and shown on the tab | Shipped | v0.2.0 |
| Tabs | Terminal session saved and restored | Shipped | v0.4.0 |
| Tabs | Tab and group icon customiser, with colour picker | Shipped | v0.7.0 |
| Agents | Agent state on the tab: running, idle, error | Shipped | v0.2.0 |
| Agents | Claude plan tag on the tab | Shipped | v0.2.0 |
| Agents | One-click hook install for Claude, Codex and OpenCode | Shipped | v0.2.0 |
| Agents | Agent conversation resumed when a tab reopens | Shipped | v0.4.0 |
| Agents | Start an agent from the sidebar, a group or a tab | Shipped | v0.7.0 |
| Agents | Ended sessions are not resumed on the next launch | Shipped | v0.7.0 |
| Agents | Agent processes are killed when a tab or window closes | Shipped | v0.7.0 |
| Agents | Follow the agent as it edits files | Planned | — |
| Agents | An MCP server: 25 tools over terminals, groups, the editor, diagnostics, language servers and worktrees | Shipped | v0.12.0 |
| Git | Repository status panel | Shipped | v0.2.0 |
| Git | Diff, split horizontal and vertical | Shipped | v0.6.0 |
| Git | File context menu | Shipped | v0.7.0 |
| Git | Add to .gitignore, tracked files included | Shipped | v0.7.0 |
| Git | Branch review: commits and files against the base | Shipped | v0.8.0 |
| Git | Search inside the git panel | Planned | — |
| Git | Worktrees: pane, create, adopt, clean up, setup hooks | Shipped | v0.9.0 |
| Git | Worktrees: one section per repository in a workspace | Shipped | v0.9.0 |
| Git | Switch a terminal's worktree from its row, group or toolbar | Shipped | v0.9.0 |
| Git | Open editor tabs follow the switch; unsaved ones stay behind | Shipped | v0.9.0 |
| Git | A file from a worktree its terminal left says so, read-only when it has no counterpart | Shipped | v0.9.0 |
| Files | File explorer with a directory watcher | Shipped | v0.2.0 |
| Files | File icon themes loaded from disk | Shipped | v0.2.0 |
| Files | Remappable shortcuts, more than one per command | Shipped | v0.7.0 |
| Files | Keyboard navigation in the tree: arrows, Space, Return | Shipped | v0.8.0 |
| Editor | Code editor inside the terminal pane | Shipped | v0.2.0 |
| Editor | Installing a language lights up an open file, with no tab switch | Shipped | v0.21.0 |
| Editor | Syntax highlighting, 19 languages | Shipped | v0.2.0 |
| Editor | Minimap, gutter, current-line band | Shipped | v0.2.0 |
| Editor | Workspace text search | Shipped | v0.2.0 |
| Editor | Auto-close brackets and quotes, per language | Shipped | v0.5.0 |
| Editor | Auto-close tags | Shipped | v0.5.0 |
| Editor | Markdown preview | Shipped | v0.6.0 |
| Editor | Diff presentation in the editor | Shipped | v0.6.0 |
| Editor | Bracket pair match under the cursor | Shipped | v0.7.0 |
| Editor | Markdown snippets on `/` | Shipped | v0.7.0 |
| Editor | Format with the project's Prettier, and on save | Shipped | v0.7.0 |
| Editor | Context menu built from the available commands | Shipped | v0.7.0 |
| Editor | Undo and redo, by menu and by ⌘Z | Shipped | v0.8.0 |
| Editor | Thin overlay scrollbars | Shipped | v0.8.0 |
| Editor | Return keeps the line's indentation | Shipped | v0.8.0 |
| Editor | Return continues a Markdown list, and ends an empty one | Shipped | v0.8.0 |
| Editor | Scroll sync between raw and rendered Markdown | Shipped | v0.6.0 |
| Editor | Move a line or a selected block, ⇧⌥↑ and ⇧⌥↓ | Shipped | v0.8.0 |
| Editor | Image and PDF viewers, fitted to the pane | Shipped | v0.8.0 |
| Editor | Zoom by button, ⌘+scroll, pinch, and ⌘+/−/0 | Shipped | v0.8.0 |
| Editor | Page thumbnails beside a PDF, where the minimap sits | Shipped | v0.8.0 |
| Editor | An SVG opens as a picture, with its markup one press away | Shipped | v0.8.0 |
| Editor | A CSV opens as a table, with its text one press away | Shipped | v0.8.0 |
| Editor | Attach the editor line to the agent prompt, ⌘K and ⇧⌘K | Shipped | v0.9.0 |
| Editor | Multi-cursor | Planned | — |
| Language | Language servers over LSP | Shipped | v0.2.0 |
| Language | Hover, definition, references, rename | Shipped | v0.2.0 |
| Language | Completion list with icons and detail | Shipped | v0.5.0 |
| Language | Documentation panel beside the list | Shipped | v0.5.0 |
| Language | Language extensions from a manifest | Shipped | v0.5.0 |
| Language | More than one server per file | Shipped | v0.5.0 |
| Language | Tailwind classes inside class attributes | Shipped | v0.8.0 |
| Language | CSS completion inside a template literal | Planned | — |
| Settings | Appearance, theme browser, font picker | Shipped | v0.2.0 |
| Settings | App icon | Shipped | v0.2.0 |
| Settings | Files and editor | Shipped | v0.2.0 |
| Settings | Language servers, with install and uninstall | Shipped | v0.3.0 |
| Settings | Both TypeScript servers listed apart, installed on their own | Shipped | v0.8.0 |
| Settings | Keyboard shortcuts, with collision warnings | Shipped | v0.4.0 |
| Settings | Completion, globally and per language | Shipped | v0.5.0 |
| Agents | Six agents: Claude Code, Codex, OpenCode, Antigravity, Kimi Code, Pi | Shipped | v0.14.0 |
| Agents | MCP permissions: four capabilities, three scopes, granted by the reader | Shipped | v0.12.0 |
| Agents | MCP handshake verifies the caller's pid against the socket's peer | Shipped | v0.12.0 |
| Agents | Register the MCP server into an agent's own config, JSON and TOML | Shipped | v0.12.0 |
| Agents | `focus_terminal` brings Phantom forward, not only the sidebar's selection | Shipped | v0.21.0 |
| Agents | Every session in the app on one screen, grouped by project | Shipped | v0.22.0 |
| Agents | Answer or interrupt a waiting agent without leaving that screen | Shipped | v0.22.0 |
| Git | Conflicts resolved in the file itself, and staged from the same pane | Shipped | v0.12.0 |
| Editor | The editor divides into a grid, and the grid is restored | Shipped | v0.11.0 |
| Editor | Undo history survives closing the file, and closing the app | Shipped | v0.13.0 |
| Editor | Hot exit: an unsaved file is kept and comes back as it was | Shipped | v0.13.0 |
| Editor | Add the import a file has not made yet, from the quick fix | Shipped | v0.13.0 |
| Editor | An extension can draw an editor, bound to a file name | Shipped | v0.19.0 |
| Language | Formatters declared by a manifest, for every language | Shipped | v0.14.0 |
| Language | No language is compiled in: grammars, servers and icons all come from extensions | Shipped | v0.17.0 |
| Language | TextMate grammars, matched with Oniguruma | Shipped | v0.17.0 |
| Language | A server reads its settings through `workspace/configuration` | Shipped | v0.18.0 |
| Language | Pull diagnostics, for a server that answers only when asked | Shipped | v0.18.0 |
| Extensions | An extension store, backed by an index published as a release asset | Shipped | v0.16.0 |
| Extensions | Every download verified against a sha256 before it is unpacked | Shipped | v0.16.0 |
| Extensions | A document page rendered without downloading the code | Shipped | v0.16.0 |
| Extensions | Icon packs come from the store, not from the binary | Shipped | v0.19.0 |
| Extensions | An extension can draw a sidebar panel, in TypeScript | Shipped | v0.19.0 |
| Extensions | A page reaches the filesystem only through methods its manifest declared | Shipped | v0.19.0 |
| Extensions | A toast suggests the extension a file needs, and the programs it still wants | Shipped | v0.21.0 |
| Extensions | A project suggests its own extensions in `.phantom/suggestions.json` | Shipped | v0.21.0 |
| Appearance | Icon themes carry a light half as well as a dark one | Shipped | v0.18.0 |
| Appearance | A file icon reads the project's dependencies, not only the suffix | Shipped | v0.18.0 |
| Appearance | Translucency drawn on a material: Soft and Deep | Shipped | v0.20.0 |
| Appearance | A window follows a theme change instead of keeping the one it was born in | Shipped | v0.20.0 |
| Windows | A welcome tour on first launch | Shipped | v0.14.0 |
| Windows | Each window has one owner; settings are grouped by surface | Shipped | v0.10.0 |
| Windows | Two builds keep separate config, state, socket and hooks | Shipped | v0.14.0 |
| Updates | Over-the-air updates through a Sparkle appcast on the Releases page | Shipped | v0.15.0 |
| Updates | Automatic-update switches, and a manual check, in Settings | Shipped | v0.20.0 |
| Updates | Two builds per release, universal and Apple silicon, each on its own feed | Shipped | v0.21.0 |

Versions come from the first release tag containing each feature's introducing
commit, so `v0.2.0` covers everything the fork shipped in its first release.
