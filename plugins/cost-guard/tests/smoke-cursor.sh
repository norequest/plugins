#!/usr/bin/env bash
# cost-guard :: Cursor install smoke test (integration).
#
# Installs cost-guard into a throwaway "project" via install.sh, then fires the
# full hook lifecycle the way Cursor actually does: the generated command string,
# run with cwd = the project root, the Cursor-shaped payload on stdin. Asserts
# the native decision shape ({"permission":"allow"} / permission:"deny" with the
# message twins) and the session ledger, then repeats the check against the
# NATIVE marketplace wiring (adapters/cursor/hooks.json, ${CLAUDE_PLUGIN_ROOT}),
# and finally that uninstall cleans up.
#
# This drives the real adapter + real core at the real cwd Cursor uses. The one
# thing it cannot cover from a shell is Cursor's OWN parse of .cursor/hooks.json
# (failClosed handling, which payload fields it passes); that needs the IDE.
#
# Requires bash + jq (both hard deps of cost-guard). Usage, from the repo root:
#   bash plugins/cost-guard/tests/smoke-cursor.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")           # plugins/cost-guard
INSTALL="$REPO/install/install.sh"
NATIVE_HOOKS="$REPO/adapters/cursor/hooks.json"

PROJ=$(mktemp -d 2>/dev/null || mktemp -d -t cgproj)
STATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgstate)
LOG=$(mktemp -d 2>/dev/null || mktemp -d -t cglog)
NSTATE=$(mktemp -d 2>/dev/null || mktemp -d -t cgnstate)
trap 'rm -rf "$PROJ" "$STATE" "$LOG" "$NSTATE"' EXIT

# a plausible "real project"
printf '{\n  "name": "demo-app"\n}\n' > "$PROJ/package.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \xe2\x9c\x97 %s  (%s)\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2] in [$3]" ;; esac; }
isfile() { if [ -f "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi; }

echo "=== 1. install into the project ==="
"$INSTALL" cursor "$PROJ" >/dev/null
HJ="$PROJ/.cursor/hooks.json"
isfile ".cursor/hooks.json written" "$HJ"
if jq -e . "$HJ" >/dev/null 2>&1; then ok ".cursor/hooks.json is valid JSON"; else bad "valid JSON" "jq failed"; fi
if [ -x "$PROJ/.cursor/hooks/cost-guard/adapter.sh" ]; then ok "adapter.sh installed +x"; else bad "adapter.sh +x" "missing"; fi
isfile "core/guard.sh bundled" "$PROJ/.cursor/hooks/cost-guard/core/guard.sh"

# Fire a hook the way Cursor does: the command string from hooks.json, cwd = the
# project root, the event payload on stdin. $1 = hooks.json event key, $2 = payload.
fire() {
  cmd=$(jq -r ".hooks.$1[0].command" "$HJ")
  ( cd "$PROJ" && printf '%s' "$2" | env \
      COST_GUARD_STATE_DIR="$STATE" COST_GUARD_LOG_DIR="$LOG" COST_GUARD_MAX_REPEATS=2 \
      sh -c "$cmd" )
}

echo "=== 2. drive the lifecycle from the project root (installed wiring) ==="
SID="cur-smoke-1"
fire sessionStart "$(jq -nc --arg s "$SID" --arg w "$PROJ" '{conversation_id:$s, workspace_roots:[$w], composer_mode:"agent"}')" >/dev/null
ok "sessionStart fired (cwd = project root)"

a=$(fire preToolUse "$(jq -nc --arg s "$SID" '{conversation_id:$s, tool_name:"Read", tool_input:{path:"README.md"}}')")
eq 'preToolUse allow -> {"permission":"allow"}' '{"permission":"allow"}' "$a"

LOOP=$(jq -nc --arg s "$SID" '{conversation_id:$s, tool_name:"Bash", tool_input:{command:"npm test"}}')
fire preToolUse "$LOOP" >/dev/null
fire preToolUse "$LOOP" >/dev/null
d=$(fire preToolUse "$LOOP")     # 3rd in a row, MAX_REPEATS=2 -> deny
eq  "loop deny -> permission=deny"    deny   "$(printf '%s' "$d" | jq -r '.permission')"
has "deny carries agent_message"      "Loop" "$(printf '%s' "$d" | jq -r '.agent_message')"
has "deny carries camelCase twin"     "Loop" "$(printf '%s' "$d" | jq -r '.agentMessage')"

fire sessionEnd "$(jq -nc --arg s "$SID" '{conversation_id:$s, reason:"completed"}')" >/dev/null
if [ -f "$LOG/sessions.jsonl" ]; then
  rec=$(tail -1 "$LOG/sessions.jsonl")
  eq "ledger platform = cursor"    cursor "$(printf '%s' "$rec" | jq -r '.platform')"
  eq "ledger sessionId"            "$SID" "$(printf '%s' "$rec" | jq -r '.sessionId')"
  eq "ledger recorded a denial"    true   "$(printf '%s' "$rec" | jq -r '(.denials >= 1)')"
  eq "ledger flagged the loop"     true   "$(printf '%s' "$rec" | jq -r '(.loops >= 1)')"
else
  bad "sessions.jsonl written" "not found"
fi

echo "=== 3. native marketplace wiring (\${CLAUDE_PLUGIN_ROOT}) resolves from project cwd ==="
ncmd=$(jq -r '.hooks.preToolUse[0].command' "$NATIVE_HOOKS")
has "native command references CLAUDE_PLUGIN_ROOT" "CLAUDE_PLUGIN_ROOT" "$ncmd"
firenat() {
  cmd=$(jq -r ".hooks.$1[0].command" "$NATIVE_HOOKS")
  ( cd "$PROJ" && printf '%s' "$2" | env \
      CLAUDE_PLUGIN_ROOT="$REPO" COST_GUARD_STATE_DIR="$NSTATE" COST_GUARD_LOG_DIR="$NSTATE" COST_GUARD_MAX_REPEATS=2 \
      sh -c "$cmd" )
}
firenat sessionStart "$(jq -nc '{conversation_id:"nat1", workspace_roots:["/x"]}')" >/dev/null
na=$(firenat preToolUse "$(jq -nc '{conversation_id:"nat1", tool_name:"Read", tool_input:{path:"a"}}')")
eq "native allow resolves via var" '{"permission":"allow"}' "$na"
NL='{"conversation_id":"nat1","tool_name":"Bash","tool_input":{"command":"x"}}'
firenat preToolUse "$NL" >/dev/null
firenat preToolUse "$NL" >/dev/null
nd=$(firenat preToolUse "$NL")
eq "native loop deny resolves via var" deny "$(printf '%s' "$nd" | jq -r '.permission')"

echo "=== 4. uninstall cleans up ==="
"$INSTALL" uninstall cursor "$PROJ" >/dev/null 2>&1
if [ -d "$PROJ/.cursor/hooks/cost-guard" ]; then
  bad "uninstall removed adapter dir" "still present"
else
  ok "uninstall removed .cursor/hooks/cost-guard"
fi

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
