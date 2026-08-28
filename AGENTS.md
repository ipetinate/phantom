# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Commit Authorship

- **Never add a `Co-Authored-By` trailer naming an AI**, and never add a
  session or tool link. Commits here are authored by the person who ran the
  work, with no trailer saying otherwise.
- This is not a style preference. A trailer naming a tool as co-author makes
  a claim about who wrote the code, and it is the repository owner's to make.

## Issue and PR Guidelines

- Open an issue or a pull request when asked to, and not otherwise.
- **Always pass `--repo ipetinate/phantom`.** `gh` resolves this checkout to
  `ghostty-org/ghostty` — `remote.upstream.gh-resolved` is set to `base` — so
  a bare `gh pr create` aims at somebody else's project. It fails today only
  because the branch does not exist there.
- This section used to forbid both outright, inherited from upstream, where
  the rule exists to stop exactly the mistake above. This fork has its own
  owner and has released through pull requests since 0.1.0, so the
  prohibition is gone and the aim is stated instead.
