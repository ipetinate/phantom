# Phantom features

What Phantom adds to Ghostty, and where each piece stands. Current version:
`0.8.0-beta`. Latest release: `v0.7.0`.

The suffix says how finished a version is: `-dev` while it is being worked on,
`-beta` once it is usable but still taking fixes, and nothing at all when it is
stable.

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
| Git | Repository status panel | Shipped | v0.2.0 |
| Git | Diff, split horizontal and vertical | Shipped | v0.6.0 |
| Git | File context menu | Shipped | v0.7.0 |
| Git | Add to .gitignore, tracked files included | Shipped | v0.7.0 |
| Git | Branch review: commits and files against the base | Unverified | 0.8.0-beta |
| Git | Search inside the git panel | Planned | — |
| Git | Worktrees | Planned | — |
| Files | File explorer with a directory watcher | Shipped | v0.2.0 |
| Files | File icon themes loaded from disk | Shipped | v0.2.0 |
| Files | Remappable shortcuts, more than one per command | Shipped | v0.7.0 |
| Editor | Code editor inside the terminal pane | Shipped | v0.2.0 |
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
| Editor | Undo and redo, by menu and by ⌘Z | Unreleased | 0.8.0-beta |
| Editor | Thin overlay scrollbars | Unreleased | 0.8.0-beta |
| Editor | Return keeps the line's indentation | Unreleased | 0.8.0-beta |
| Editor | Return continues a Markdown list, and ends an empty one | Unreleased | 0.8.0-beta |
| Editor | Scroll sync between raw and rendered Markdown | Unverified | v0.6.0 |
| Editor | Move a line or a selected block, ⇧⌥↑ and ⇧⌥↓ | Unreleased | 0.8.0-beta |
| Editor | Image and PDF viewers | Unreleased | 0.8.0-beta |
| Editor | Multi-cursor | Planned | — |
| Editor | CSV viewer | Planned | — |
| Language | Language servers, 21 binaries | Shipped | v0.2.0 |
| Language | Hover, definition, references, rename | Shipped | v0.2.0 |
| Language | Completion list with icons and detail | Shipped | v0.5.0 |
| Language | Documentation panel beside the list | Shipped | v0.5.0 |
| Language | Language extensions from a manifest | Shipped | v0.5.0 |
| Language | More than one server per file | Shipped | v0.5.0 |
| Language | Tailwind classes inside class attributes | Unverified | 0.8.0-beta |
| Language | CSS completion inside a template literal | Planned | — |
| Settings | Appearance, theme browser, font picker | Shipped | v0.2.0 |
| Settings | App icon | Shipped | v0.2.0 |
| Settings | Files and editor | Shipped | v0.2.0 |
| Settings | Language servers, with install and uninstall | Shipped | v0.3.0 |
| Settings | Both TypeScript servers listed apart, installed on their own | Unreleased | 0.8.0-beta |
| Settings | Keyboard shortcuts, with collision warnings | Shipped | v0.4.0 |
| Settings | Completion, globally and per language | Shipped | v0.5.0 |

Versions come from the first release tag containing each feature's introducing
commit, so `v0.2.0` covers everything the fork shipped in its first release.
