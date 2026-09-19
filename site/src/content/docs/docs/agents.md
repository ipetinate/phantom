---
title: Agents
description: The six coding agents Phantom knows, the state it shows on a tab, session resume, and the one-click hook install.
sidebar:
  label: Agents
---

Phantom is built around running several coding agents at once. It knows six of
them, and treats an agent session as something a tab *has*, not something you
have to remember.

## Supported agents

Claude Code, Codex, OpenCode, Antigravity, Kimi Code and Pi.

Each one has a mark of its own in the sidebar, an entry in the *new terminal*
menu, and an installer for its configuration format — JSON for most, TOML for
Codex.

## Starting a session

From a group header or the new-terminal menu, pick an agent. Phantom opens a
tab in the right working directory with the agent already running. A project
group starts it at the project root; a worktree starts it in that checkout.

## The state on the tab

A row shows whether its session is **working**, **waiting on you**, or **done**.
That is the whole reason the sidebar exists: a dozen agents across a dozen
repositories are otherwise a dozen identical tabs.

The state comes from hooks the agent runs. Install them from
**Settings › Agents** with one click — Phantom writes a script into the agent's
own hooks directory and registers it. The script's name carries the build's
name, so a development build cannot overwrite the one your installed copy uses.

For Claude Code the tab also shows the current plan, when there is one.

## Every session on one screen

**Window › Agents**, or ⇧⌘A, opens a window listing every agent session in the
app — every window, every split, grouped by project. What needs you sorts to
the top: waiting and failed first, then work in flight, oldest first inside
each band, so the session that has been stuck longest is the one you see.

Each card carries the agent, its state, how long it has been in that state, the
project and branch, and the last few lines the agent printed. Three actions:

- **Open** brings that terminal forward — the right window, the right tab, the
  right split. A window sitting on another Space is left where you put it.
- **Interrupt** sends Ctrl-C.
- The text field answers the agent: what you type is sent followed by Return.

Answering is free text on purpose. Phantom knows that an agent is waiting, but
not what it is asking — the state it reports is one word with no question
attached. So the screen types what you tell it to and never guesses. For a
menu you drive with arrow keys, open the terminal and answer there.

A session appears once its agent's hooks are installed; **Settings › Agents**
installs them.

A card that says the process is gone is an agent that died without writing its
last word. Phantom checks the terminal's foreground process while this window
is open, and that check can only withdraw a claim, never make one.

## Resume

Closing a tab kills the processes inside it, agent included. Reopening the tab —
by restoring the session or from the tab's own menu — starts the agent again
with `--resume` against the conversation it had, so the session continues rather
than restarting.

Turn this off with **Restore agent sessions** in Settings.

## Letting an agent drive Phantom

An agent can also act on the window it is running in: open a file at a line,
read another terminal's output, create a worktree. That is the MCP server, and
it is documented in [The MCP server](/docs/mcp/).
