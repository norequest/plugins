#!/usr/bin/env bash
# cost-guard :: OpenAI Codex CLI adapter (bash)
#
# Usage (wired in .codex/hooks.json): adapter.sh <canonical-event>
#   session-start | pre-tool | post-tool | session-end
#
# Codex's hook contract is Claude-Code-compatible: PreToolUse/PostToolUse/
# SessionStart/Stop, payload fields session_id/tool_name/tool_input/tool_response,
# and the same hookSpecificOutput.permissionDecision {allow,deny,ask} output.
# Codex has no SessionEnd — it finalizes on Stop (wire Stop -> session-end).
#
# Requires Codex >= ~v0.117 with `features.hooks` enabled. Older Codex only has
# fire-and-forget `notify` (see README support tiers). PreToolUse interception is
# solid for Bash but reportedly uneven for apply_patch/MCP — a guardrail, not a
# sandbox. Only pre-tool writes to stdout.
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
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"session-start", sessionId:(.session_id // "unknown"), cwd:(.cwd // ""), source:(.source // ""), platform:"codex"}')
    ;;
  pre-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"pre-tool", sessionId:(.session_id // "unknown"), tool:(.tool_name // ""), args:(.tool_input // {}), platform:"codex"}')
    ;;
  post-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c '
      (.tool_response) as $r
      | (($r|type=="object") and (($r.is_error==true) or ($r.error!=null))) as $err
      | if $err
        then {event:"error", sessionId:(.session_id // "unknown"), platform:"codex"}
        else {event:"post-tool", sessionId:(.session_id // "unknown"), resultText:(($r // .tool_output // "")|tostring), platform:"codex"}
        end')
    ;;
  session-end)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"session-end", sessionId:(.session_id // "unknown"), endReason:(.reason // "stop"), platform:"codex"}')
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
