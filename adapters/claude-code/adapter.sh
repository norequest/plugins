#!/usr/bin/env bash
# cost-guard :: Claude Code adapter (bash)
#
# Usage (wired in hooks.json): adapter.sh <canonical-event>
#   session-start | pre-tool | post-tool | session-end
#
# Claude Code hook payload fields (verified against code.claude.com/docs/en/hooks):
#   session_id, cwd, source (SessionStart), tool_name, tool_input (PreToolUse),
#   tool_response (PostToolUse), reason (SessionEnd)
#
# Decision output for PreToolUse is Claude Code's hookSpecificOutput form with
# permissionDecision in {allow,deny,ask}. Only pre-tool writes to stdout; every
# other event stays silent so we never disturb Claude Code's JSON parsing.
#
# There is no dedicated tool-failure event, so the failure streak is best-effort:
# a PostToolUse whose tool_response looks like an error is routed to the core as
# an `error` instead of a `post-tool`.
set -u

EVENT="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORE=""
for c in "${COST_GUARD_CORE:-}" "$HERE/core/guard.sh" "$HERE/../../core/guard.sh"; do
  [ -n "$c" ] && [ -f "$c" ] && { CORE="$c"; break; }
done

emit_allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; }

if ! command -v jq >/dev/null 2>&1 || [ -z "$CORE" ]; then
  [ "$EVENT" = "pre-tool" ] && emit_allow
  exit 0
fi

INPUT=$(cat)

case "$EVENT" in
  session-start)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"session-start", sessionId:(.session_id // "unknown"), cwd:(.cwd // ""), source:(.source // ""), platform:"claude-code"}')
    ;;
  pre-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"pre-tool", sessionId:(.session_id // "unknown"), tool:(.tool_name // ""), args:(.tool_input // {}), platform:"claude-code"}')
    ;;
  post-tool)
    # Best-effort error detection: route obvious failures to the failure streak.
    CANON=$(printf '%s' "$INPUT" | jq -c '
      (.tool_response) as $r
      | (($r|type=="object") and (($r.is_error==true) or ($r.error!=null) or ($r.interrupted==true))) as $err
      | if $err
        then {event:"error", sessionId:(.session_id // "unknown"), platform:"claude-code"}
        else {event:"post-tool", sessionId:(.session_id // "unknown"), resultText:(($r // .tool_output // "")|tostring), platform:"claude-code"}
        end')
    ;;
  session-end)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"session-end", sessionId:(.session_id // "unknown"), endReason:(.reason // "unknown"), platform:"claude-code"}')
    ;;
  *)
    exit 0
    ;;
esac

OUT=$(printf '%s' "$CANON" | bash "$CORE")

if [ "$EVENT" = "pre-tool" ]; then
  printf '%s' "$OUT" | jq -c '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:(.decision // "allow"), permissionDecisionReason:(.reason // "")}}'
fi
exit 0
