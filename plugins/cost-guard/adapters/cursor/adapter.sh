#!/usr/bin/env bash
# cost-guard :: Cursor adapter (bash)
#
# Usage (wired in .cursor/hooks.json): adapter.sh <canonical-event>
#   session-start | pre-tool | post-tool | error | session-end
#
# Cursor hook payload fields (cursor.com/docs/hooks):
#   conversation_id (stable session id), tool_name, tool_input (preToolUse),
#   tool_output (postToolUse), reason (sessionEnd), source/composer_mode.
#
# Decision output uses Cursor's `permission` (allow|deny|ask). On preToolUse
# Cursor honors allow/deny (ask is accepted but not enforced today). `agent_message`
# is fed to the model (so it stops retrying); `user_message` is shown to the human.
# We emit BOTH snake_case and camelCase message keys because Cursor renamed them
# once already. Only pre-tool writes to stdout.
#
# Cloud caveat: Cursor cloud agents drop sessionStart/sessionEnd — the core
# bootstraps missing state lazily on the first pre-tool, so gating still works;
# only the end-of-session record is skipped in cloud.
set -u

EVENT="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORE=""
for c in "${COST_GUARD_CORE:-}" "$HERE/core/guard.sh" "$HERE/../../core/guard.sh"; do
  [ -n "$c" ] && [ -f "$c" ] && { CORE="$c"; break; }
done

if ! command -v jq >/dev/null 2>&1 || [ -z "$CORE" ]; then
  [ "$EVENT" = "pre-tool" ] && printf '{"permission":"allow"}'
  exit 0
fi

INPUT=$(cat)
SIDEXPR='(.conversation_id // .session_id // "unknown")'

case "$EVENT" in
  session-start)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"session-start\", sessionId:$SIDEXPR, cwd:(.cwd // (.workspace_roots[0] // \"\")), source:(.source // .composer_mode // \"\"), platform:\"cursor\"}")
    ;;
  pre-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"pre-tool\", sessionId:$SIDEXPR, tool:(.tool_name // \"\"), args:(.tool_input // {}), platform:\"cursor\"}")
    ;;
  post-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"post-tool\", sessionId:$SIDEXPR, resultText:((.tool_output // .output // \"\")|tostring), platform:\"cursor\"}")
    ;;
  error)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"error\", sessionId:$SIDEXPR, platform:\"cursor\"}")
    ;;
  session-end)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"session-end\", sessionId:$SIDEXPR, endReason:(.reason // \"unknown\"), platform:\"cursor\"}")
    ;;
  *)
    exit 0
    ;;
esac

OUT=$(printf '%s' "$CANON" | bash "$CORE")

if [ "$EVENT" = "pre-tool" ]; then
  printf '%s' "$OUT" | jq -c '
    (.decision // "allow") as $d | (.reason // "") as $r
    | if $d == "allow"
      then {permission:"allow"}
      else {permission:$d, continue:true, user_message:$r, agent_message:$r, userMessage:$r, agentMessage:$r}
      end'
fi
exit 0
