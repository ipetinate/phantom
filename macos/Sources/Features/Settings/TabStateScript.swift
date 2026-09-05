import Foundation

enum TabStateScript {
    static let releaseName = "phantom-tab-state.sh"

    static var fileName: String { PhantomBuild.fileName(releaseName) }

    static func fileName(forBundleID id: String) -> String {
        PhantomBuild.fileName(releaseName, forBundleID: id)
    }

    static func options(of descriptor: AgentDescriptor) -> HooksIntegration.ScriptOptions {
        descriptor.hooks?.scriptOptions
            ?? HooksIntegration.ScriptOptions(subdirectory: "", sessionKeys: ["session_id"])
    }

    static func arguments(
        agent: String,
        state: String,
        options: HooksIntegration.ScriptOptions,
        reply: String? = nil
    ) -> [String] {
        var arguments: [String] = []
        if !state.isEmpty { arguments.append(state) }
        arguments += ["--agent", agent]
        for key in options.sessionKeys {
            arguments += ["--session-key", key]
        }
        if let rule = options.stateFromPayload {
            arguments += ["--state-from", "\(rule.key)=\(rule.value):\(rule.state)"]
        }
        if let reply {
            arguments += ["--reply", reply]
        }
        return arguments
    }

    static func commandLine(scriptPath: String, arguments: [String]) -> String {
        (["'\(scriptPath)'"] + arguments.map(shellWord)).joined(separator: " ")
    }

    private static let bareWordCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:=/-"
    )

    static func shellWord(_ word: String) -> String {
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(bareWordCharacters.contains) else {
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return word
    }

    static let body = #"""
    #!/bin/bash
    # Reports a coding agent's session state to the Phantom sidebar.
    # No-op outside Phantom (env var only exists in Phantom terminals).
    # The atomic write-then-rename is what triggers the directory watch.

    # Absent on purpose for SessionStart, which reports identity rather than
    # activity: no argument means an empty first line, which the sidebar reads
    # as "an agent lives here and is doing nothing in particular". Every other
    # event passes a word.
    STATE=""
    case "$1" in
      ""|--*) ;;
      *) STATE="$1"; shift ;;
    esac

    AGENT=""
    KEYS=""
    FROM_KEY=""
    FROM_VALUE=""
    FROM_STATE=""
    REPLY=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --agent) AGENT="$2"; shift 2 ;;
        --session-key) KEYS="$KEYS $2"; shift 2 ;;
        --state-from)
          FROM_KEY="${2%%=*}"
          REST="${2#*=}"
          FROM_VALUE="${REST%%:*}"
          FROM_STATE="${REST#*:}"
          shift 2 ;;
        --reply) REPLY="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    # Antigravity expects a JSON object back from every hook, and the shape is
    # per-event: Stop takes a `decision`, everything else takes an empty
    # object. Printed first, before any of the work below, so that no missing
    # state file and no failed write can cost the agent its reply — a hook
    # that answers nothing is a hook whose runner has to guess.
    if [ -n "$REPLY" ]; then
      printf '%s\n' "$REPLY"
    fi

    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0

    # Each agent hands its hook a payload as JSON on stdin, and the session id
    # lives there and nowhere else the hook can see. Read it only when stdin is
    # not a terminal, so running this script by hand cannot sit waiting for
    # input that will never arrive.
    PAYLOAD=""
    if [ ! -t 0 ]; then
      PAYLOAD=$(cat 2>/dev/null)
    fi
    FLAT=$(printf '%s' "$PAYLOAD" | tr -d '\n')

    # Deliberately not jq: a hook that needs jq is a hook that silently stops
    # reporting on every machine without it. Lifting one string out of a flat
    # JSON object is within grep and sed's reach, and anything they cannot make
    # sense of degrades to reporting the state alone.
    #
    # The FIRST match, and that is the whole point. A `sed` opening with `.*` is
    # greedy, so it lands on the LAST occurrence in the payload — and tool
    # events nest one inside `tool_input`/`tool_response`: a subagent call, an
    # MCP tool that hands back a session of its own. That nested id is a
    # perfectly well-formed UUID, so the filter below passes it and nothing
    # downstream objects, and the tab comes back in a conversation it never
    # held. In every payload these CLIs emit the session's own id is a
    # top-level field and so precedes anything nested; taking the first match
    # is what keeps them apart.
    json_string() {
      printf '%s' "$FLAT" \
        | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -n 1 \
        | sed 's/.*"\([^"]*\)"$/\1/'
    }

    # A SessionStart fired by a compaction is not a session starting: the agent
    # is mid-turn and about to carry on. Blanking the mark there is what left a
    # three-minute compaction looking like nothing at all — or, until the next
    # event, like the API error that triggered it.
    #
    # Only consulted for the event that passes no word of its own, so no other
    # payload's value can reach this. `startup`, `resume` and `clear` all
    # fall through to the empty word they had.
    if [ -z "$STATE" ] && [ -n "$FROM_KEY" ]; then
      if [ "$(json_string "$FROM_KEY")" = "$FROM_VALUE" ]; then
        STATE="$FROM_STATE"
      fi
    fi

    # Refuse anything a shell would read as more than one word, and anything
    # starting with a dash: this value is eventually typed at a prompt after
    # the agent's resume flag, where an id spelled like a flag is a flag.
    #
    # A function because both sources of an id have to pass through it. When
    # only the payload was filtered, a corrupt value read back out of the file
    # was copied forward verbatim on every later event, so one bad write stuck
    # to the tab permanently: the file still looked like it held an id, and the
    # resume stayed silently imprecise with nothing able to heal it.
    sanitize_session() {
      case "$1" in
        ""|-*|*[!A-Za-z0-9._-]*) return 0 ;;
        *) printf '%s' "$1" ;;
      esac
    }

    # Filtering inside the loop rather than after it, so that a key which
    # matches something unusable does not shadow the keys still untried.
    SESSION=""
    for KEY in $KEYS; do
      [ -n "$SESSION" ] && break
      SESSION=$(sanitize_session "$(json_string "$KEY")")
    done

    # An event arriving without an id must not erase the one on record. The
    # last write before a quit is the one a restore reads, and nothing says
    # that write will be an event that carried the id.
    if [ -z "$SESSION" ] && [ -f "$GHOSTTY_TAB_STATE_FILE" ]; then
      SESSION=$(sanitize_session "$(sed -n 's/^session=//p' \
        "$GHOSTTY_TAB_STATE_FILE" | head -n 1)")
    fi

    # A temp name private to this invocation. A fixed `.tmp` is one path shared
    # by everything writing this tab — two hooks on parallel tool calls, a
    # second agent in the same terminal, another integration on the same events
    # — and two of them truncating that one file interleaves their bytes. The
    # rename that wins carries the mixture, which is how a `session=` line
    # arrives cut in half; the one that loses renames a file the winner already
    # took, so its error goes to /dev/null rather than into the agent's
    # transcript, and the fragment it left behind is removed.
    #
    # The name still cannot be mistaken for a state file: TabStateCenter only
    # reads entries whose whole name parses as a UUID, and this one does not.
    TMP="$GHOSTTY_TAB_STATE_FILE.$$.tmp"

    # State stays alone on the first line: a Phantom old enough to read only
    # that line keeps reading this file correctly.
    #
    # `2>/dev/null` comes BEFORE `> "$TMP"`, and the order is the whole point.
    # Bash applies redirections left to right, so a stderr redirect written
    # after the one that fails is installed too late to catch its own
    # complaint: opening an unwritable path prints "No such file or directory"
    # to whatever stderr was at that moment. Silencing stderr first is what
    # keeps that message out of the reader's transcript, and a hook runner can
    # put it there. Measured, not assumed — a test fires this script at a path
    # inside a directory that does not exist and asserts stderr stays empty.
    {
      printf '%s\nagent=%s\n' "$STATE" "$AGENT"
      if [ -n "$SESSION" ]; then
        printf 'session=%s\n' "$SESSION"
      fi
    } 2>/dev/null > "$TMP" \
      && mv "$TMP" "$GHOSTTY_TAB_STATE_FILE" 2>/dev/null \
      || rm -f "$TMP" 2>/dev/null
    exit 0

    """#
}

extension HooksIntegration {
    var scriptOptions: ScriptOptions? {
        switch self {
        case .json(let hooks): return hooks.script
        case .toml(let hooks): return hooks.script
        case .file: return nil
        }
    }
}
