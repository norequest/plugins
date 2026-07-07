#!/usr/bin/env bash
# cost-guard :: Google Gemini CLI adapter (bash)
#
# Usage (wired in settings.json hooks block): adapter.sh <canonical-event>
#   session-start | pre-tool | post-tool | session-end
#
# Gemini hook contract (docs/hooks): events BeforeTool/AfterTool/SessionStart/
# SessionEnd; snake_case tool_name/tool_input/tool_response; decision is TOP-LEVEL
# {"decision":"deny","reason":"...","continue":false} (deny|block aliases). There
# is no "ask" — a soft checkpoint degrades to allow. Gemini requires stdout to be
# PURE JSON, so we print NOTHING on allow and only the deny object on deny.
#
# Requires Gemini CLI >= v0.26.0 (hooks GA). Below that, only static
# coreTools/excludeTools allowlists exist (see README support tiers).
set -u

EVENT="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORE=""
for c in "${COST_GUARD_CORE:-}" "$HERE/core/guard.sh" "$HERE/../../core/guard.sh"; do
  [ -n "$c" ] && [ -f "$c" ] && { CORE="$c"; break; }
done

# jq/core missing: fail OPEN by staying silent (no decision == proceed).
if ! command -v jq >/dev/null 2>&1 || [ -z "$CORE" ]; then
  exit 0
fi

INPUT=$(cat)
SIDEXPR='(.session_id // env.GEMINI_SESSION_ID // "unknown")'

case "$EVENT" in
  session-start)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"session-start\", sessionId:$SIDEXPR, cwd:(.cwd // \"\"), source:(.source // \"\"), platform:\"gemini\"}")
    ;;
  pre-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"pre-tool\", sessionId:$SIDEXPR, tool:(.tool_name // \"\"), args:(.tool_input // {}), platform:\"gemini\"}")
    ;;
  post-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c "
      (.tool_response) as \$r
      | ((\$r|type==\"object\") and ((\$r.is_error==true) or (\$r.error!=null))) as \$err
      | if \$err
        then {event:\"error\", sessionId:$SIDEXPR, platform:\"gemini\"}
        else {event:\"post-tool\", sessionId:$SIDEXPR, resultText:((\$r // \"\")|tostring), platform:\"gemini\"}
        end")
    ;;
  session-end)
    CANON=$(printf '%s' "$INPUT" | jq -c "{event:\"session-end\", sessionId:$SIDEXPR, endReason:(.reason // \"unknown\"), platform:\"gemini\"}")
    ;;
  *)
    exit 0
    ;;
esac

OUT=$(printf '%s' "$CANON" | bash "$CORE")

if [ "$EVENT" = "pre-tool" ]; then
  # Gemini only understands deny/block. allow and ask both proceed -> emit nothing.
  printf '%s' "$OUT" | jq -cj '
    if (.decision // "allow") == "deny"
    then {decision:"deny", reason:(.reason // ""), continue:false}
    else empty
    end'
fi
exit 0
