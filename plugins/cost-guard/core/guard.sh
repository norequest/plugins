#!/usr/bin/env bash
# cost-guard :: platform-neutral core engine (bash + jq)
#
# Reads ONE canonical JSON object on stdin and dispatches on `.event`:
#
#   session-start  {event,sessionId,cwd,source,platform,user?,gitEmail?,host?}
#   pre-tool       {event,sessionId,tool,args,platform}   -> emits {decision,reason}
#   post-tool      {event,sessionId,resultText,platform}
#   error          {event,sessionId,platform}
#   session-end    {event,sessionId,endReason,platform}
#
# Only `pre-tool` writes to stdout — the escalation-ladder decision:
#   {"decision":"allow|deny|ask","reason":"..."}
# Adapters translate that into each agent's native permission format.
#
# All agent-specific field names live in the adapters; this file never sees
# them. Keep it fast and local-only: the network call happens on session-end,
# never in the pre-tool hot path.
#
# Fail policy (mirrors the original hook): missing jq or a bookkeeping error
# on pre-tool -> ALLOW (never brick a session on our account).
set -u

emit_allow() { printf '{"decision":"allow","reason":""}'; }

# jq is our only hard dependency. Without it we cannot do bookkeeping — for the
# gating event, fail OPEN; for passive events, do nothing.
if ! command -v jq >/dev/null 2>&1; then
  INPUT=$(cat 2>/dev/null || true)
  case "$(printf '%s' "$INPUT" | tr -dc 'a-z-' | grep -o 'pre-tool' 2>/dev/null || true)" in
    pre-tool) emit_allow ;;
  esac
  exit 0
fi

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.event // ""')
SID=$(printf '%s' "$INPUT" | jq -r '.sessionId // "unknown"')
PLATFORM=$(printf '%s' "$INPUT" | jq -r '.platform // "unknown"')

STATE_DIR="${COST_GUARD_STATE_DIR:-${TMPDIR:-/tmp}/cost-guard}"
LOG_DIR="${COST_GUARD_LOG_DIR:-$HOME/.cost-guard}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/$SID.json"
NOW=$(date +%s)

# ---- Tunables (env-overridable) ----
MAX_CALLS="${COST_GUARD_MAX_CALLS:-120}"          # hard ceiling on tool calls
SOFT_CALLS="${COST_GUARD_SOFT_CALLS:-50}"         # soft threshold -> ask
MAX_REPEATS="${COST_GUARD_MAX_REPEATS:-3}"        # identical-call loop limit
MAX_MINUTES="${COST_GUARD_MAX_MINUTES:-30}"       # wall-clock budget
MAX_FAIL_STREAK="${COST_GUARD_MAX_FAIL_STREAK:-5}"
SOFT_ACTION="${COST_GUARD_SOFT_ACTION:-ask}"      # set to "deny" for CI / pipe mode

bootstrap_state() { # $1=cwd $2=source ; capture local identity (hooks carry none)
  local cwd="${1:-}" src="${2:-}"
  local git_email os_user host_val
  git_email=$(git config user.email 2>/dev/null || echo "")
  os_user="${USER:-${USERNAME:-unknown}}"
  host_val=$(hostname 2>/dev/null || echo "unknown")
  jq -n \
    --arg sid "$SID" --arg cwd "$cwd" --arg src "$src" --arg plat "$PLATFORM" \
    --arg user "$os_user" --arg email "$git_email" --arg host "$host_val" \
    --argjson now "$NOW" \
    '{sessionId:$sid, platform:$plat, cwd:$cwd, source:$src,
      user:$user, gitEmail:$email, host:$host, startedAt:$now,
      count:0, hashes:{}, failStreak:0, outputBytes:0, denials:0, asks:0}' \
    > "$STATE"
}

case "$EVENT" in

# ---------------------------------------------------------------- session-start
session-start)
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
  SRC=$(printf '%s' "$INPUT" | jq -r '.source // ""')
  bootstrap_state "$CWD" "$SRC"
  exit 0
  ;;

# -------------------------------------------------------------------- pre-tool
pre-tool)
  # State may be missing (sessionStart hook skipped, or platform has none) — bootstrap.
  [ -f "$STATE" ] || bootstrap_state "" ""

  # Fingerprint = tool name + normalized args (sorted keys for stability).
  HASH_INPUT=$(printf '%s' "$INPUT" | jq -cS '{t:(.tool // ""), a:(.args // {})}')
  if command -v sha1sum >/dev/null 2>&1; then
    HASH=$(printf '%s' "$HASH_INPUT" | sha1sum | cut -d' ' -f1)
  else
    HASH=$(printf '%s' "$HASH_INPUT" | shasum | cut -d' ' -f1)   # macOS
  fi

  TMP="$STATE.tmp.$$"
  jq --arg h "$HASH" '.count += 1 | .hashes[$h] = ((.hashes[$h] // 0) + 1)' "$STATE" > "$TMP" \
    && mv "$TMP" "$STATE" || { emit_allow; exit 0; }

  COUNT=$(jq -r '.count' "$STATE")
  REPEATS=$(jq -r --arg h "$HASH" '.hashes[$h]' "$STATE")
  FAILS=$(jq -r '.failStreak // 0' "$STATE")
  STARTED=$(jq -r '.startedAt // 0' "$STATE")
  ELAPSED_MIN=$(( (NOW - STARTED) / 60 ))

  decide() { # $1=allow|deny|ask $2=reason ; record it in state, emit, exit
    local key="denials"; [ "$1" = "ask" ] && key="asks"
    local t2="$STATE.tmp2.$$"
    jq ".$key += 1" "$STATE" > "$t2" && mv "$t2" "$STATE"
    jq -cn --arg d "$1" --arg r "$2" '{decision:$d, reason:$r}'
    exit 0
  }

  # 1. Loop detection — catches runaways earliest
  if [ "$REPEATS" -gt "$MAX_REPEATS" ]; then
    decide deny "Loop detected: this exact tool call was already made $((REPEATS-1)) times. Do NOT retry it again. Explain what is blocking you and either try a genuinely different approach or summarize and stop."
  fi
  # 2. Failure streak — agent fighting the environment
  if [ "$FAILS" -ge "$MAX_FAIL_STREAK" ]; then
    decide deny "$FAILS consecutive tool failures. Stop retrying. Summarize the errors encountered and report the blocker instead of attempting further tool calls."
  fi
  # 3. Hard ceilings — kill switch
  if [ "$COUNT" -ge "$MAX_CALLS" ]; then
    decide deny "Session tool budget exhausted ($COUNT/$MAX_CALLS calls). Stop all further work immediately and produce a final summary of what was completed and what remains."
  fi
  if [ "$ELAPSED_MIN" -ge "$MAX_MINUTES" ]; then
    decide deny "Session time budget exhausted (${ELAPSED_MIN} min / ${MAX_MINUTES} min). Stop all further work and produce a final summary."
  fi
  # 4. Soft threshold — human checkpoint (interactive) or early stop (CI)
  if [ "$COUNT" -eq "$SOFT_CALLS" ] || { [ "$COUNT" -gt "$SOFT_CALLS" ] && [ $(( (COUNT - SOFT_CALLS) % 25 )) -eq 0 ]; }; then
    decide "$SOFT_ACTION" "Cost checkpoint: $COUNT tool calls used in this session (soft limit $SOFT_CALLS, hard limit $MAX_CALLS). Confirm to continue."
  fi
  # 5. Default
  emit_allow
  exit 0
  ;;

# -------------------------------------------------------------------- post-tool
post-tool)
  [ -f "$STATE" ] || exit 0
  BYTES=$(printf '%s' "$INPUT" | jq -r '(.resultText // "") | tostring | length')
  TMP="$STATE.tmp.$$"
  jq --argjson b "${BYTES:-0}" '.failStreak = 0 | .outputBytes += $b' "$STATE" > "$TMP" \
    && mv "$TMP" "$STATE"
  exit 0
  ;;

# ------------------------------------------------------------------------ error
error)
  [ -f "$STATE" ] || exit 0
  TMP="$STATE.tmp.$$"
  jq '.failStreak = ((.failStreak // 0) + 1)' "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  exit 0
  ;;

# ------------------------------------------------------------------ session-end
session-end)
  REASON=$(printf '%s' "$INPUT" | jq -r '.endReason // "unknown"')
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if [ -f "$STATE" ]; then
    RECORD=$(jq -c --arg reason "$REASON" --argjson now "$NOW" \
      '. + {
         endReason: $reason,
         endedAt: $now,
         durationSec: ($now - (.startedAt // $now)),
         loops: ([.hashes[] | select(. > 1)] | length),
         maxRepeats: ([.hashes[]] | max // 0)
       } | del(.hashes)' "$STATE")
  else
    RECORD=$(jq -c -n --arg sid "$SID" --arg plat "$PLATFORM" --arg reason "$REASON" --argjson now "$NOW" \
      '{sessionId:$sid, platform:$plat, endReason:$reason, endedAt:$now, note:"no state found"}')
  fi

  printf '%s\n' "$RECORD" >> "$LOG_DIR/sessions.jsonl"
  case "$REASON" in
    error|timeout|abort)
      printf '%s\n' "$RECORD" >> "$LOG_DIR/wasted-sessions.jsonl" ;;
  esac

  if [ -n "${COST_GUARD_COLLECTOR_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    printf '%s' "$RECORD" | curl -s -m 10 -X POST \
      -H 'Content-Type: application/json' \
      --data-binary @- "$COST_GUARD_COLLECTOR_URL" >/dev/null 2>&1 || true
  fi

  rm -f "$STATE" "$STATE".tmp.* "$STATE".tmp2.* 2>/dev/null
  exit 0
  ;;

*)
  # Unknown event: do nothing, succeed.
  exit 0
  ;;
esac
