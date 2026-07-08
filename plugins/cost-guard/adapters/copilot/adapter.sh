#!/usr/bin/env bash
# cost-guard :: GitHub Copilot CLI / cloud-agent adapter (bash)
#
# Usage (wired in cost-guard.json): adapter.sh <canonical-event>
#   session-start | pre-tool | post-tool | error | session-end
#
# Job: translate Copilot's hook payload -> canonical, call the neutral core,
# and (for pre-tool only) translate the core's decision back into Copilot's
# {permissionDecision, permissionDecisionReason} format.
#
# Copilot hook payload fields:
#   sessionId, cwd, source, toolName, toolArgs,
#   toolResult.textResultForLlm | toolResult, reason
set -u

EVENT="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate the neutral core across both the repo layout (adapters/<p>/ next to
# core/) and a self-contained install (core/ bundled beside the adapter).
CORE=""
for c in "${COST_GUARD_CORE:-}" "$HERE/core/guard.sh" "$HERE/../../core/guard.sh"; do
  [ -n "$c" ] && [ -f "$c" ] && { CORE="$c"; break; }
done

# Fail OPEN on the gating event if jq or the core is unavailable — never brick a session.
if ! command -v jq >/dev/null 2>&1 || [ -z "$CORE" ]; then
  [ "$EVENT" = "pre-tool" ] && printf '{"permissionDecision":"allow"}'
  exit 0
fi

INPUT=$(cat)

case "$EVENT" in
  session-start)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"session-start", sessionId:(.sessionId // "unknown"), cwd:(.cwd // ""), source:(.source // ""), platform:"copilot"}')
    ;;
  pre-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"pre-tool", sessionId:(.sessionId // "unknown"), tool:(.toolName // ""), args:(.toolArgs // {}), platform:"copilot"}')
    ;;
  post-tool)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"post-tool", sessionId:(.sessionId // "unknown"), resultText:((.toolResult.textResultForLlm // .toolResult // "") | tostring), platform:"copilot"}')
    ;;
  error)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"error", sessionId:(.sessionId // "unknown"), platform:"copilot"}')
    ;;
  session-end)
    CANON=$(printf '%s' "$INPUT" | jq -c '{event:"session-end", sessionId:(.sessionId // "unknown"), endReason:(.reason // "unknown"), platform:"copilot"}')
    ;;
  *)
    exit 0
    ;;
esac

OUT=$(printf '%s' "$CANON" | bash "$CORE")

# Only pre-tool produces a decision that Copilot consumes.
if [ "$EVENT" = "pre-tool" ]; then
  printf '%s' "$OUT" | jq -c '{permissionDecision:(.decision // "allow"), permissionDecisionReason:(.reason // "")}'
fi
exit 0
