# cost-guard — platform-neutral design (2026-07-08)

## Origin

Started life as `copilot-cost-guard`: a GitHub Copilot-specific cost/runaway
guard built on Copilot's hook system, with parallel bash + PowerShell scripts
(so already **OS**-neutral) and an optional Python collector. The logic was
portable but every script was hardwired to Copilot's hook schema
(`sessionId`, `toolName`/`toolArgs`, `permissionDecision`, `.github/hooks/`).

Goal of this rework: make it **agent-platform-neutral** — one guard that governs
Claude Code, GitHub Copilot, Cursor, OpenAI Codex, and Google Gemini CLI — and
ship it as both a **Claude Code plugin marketplace** and a **generic repo**.

## The one idea: a frozen canonical contract

All shared logic lives in a single **core**. Each agent gets a thin **adapter**
that only translates JSON in and out. No ladder logic is ever duplicated.

```
adapter (per platform)                 core (once)
  platform payload ──normalize──▶  canonical JSON ──▶ escalation ladder + state
  platform decision ◀─denormalize── {decision,reason}      + logging
```

### Canonical input (adapter → core, on stdin)

```json
{
  "event": "session-start | pre-tool | post-tool | error | session-end",
  "sessionId": "string",
  "tool": "string",          // pre-tool: for the loop fingerprint
  "args": {},                // pre-tool: for the loop fingerprint
  "resultText": "string",    // post-tool: bytes proxy for context growth
  "cwd": "string",           // session-start
  "source": "string",        // session-start
  "endReason": "string",     // session-end
  "platform": "claude-code | copilot | cursor | codex | gemini"
}
```

### Canonical output (core → adapter, pre-tool only, on stdout)

```json
{ "decision": "allow | deny | ask", "reason": "string" }
```

Every other event produces no stdout; the core does its bookkeeping/logging and
exits 0.

## The escalation ladder (unchanged, now platform-neutral)

Evaluated in `pre-tool`, in order — the same ladder the Copilot version shipped:

1. **Loop** — same `{tool,args}` fingerprint repeated > `MAX_REPEATS` → **deny**
   with an instructive reason that un-sticks the agent.
2. **Failure streak** — ≥ `MAX_FAIL_STREAK` consecutive errors → **deny**.
3. **Hard ceiling** — `MAX_CALLS` calls or `MAX_MINUTES` wall-clock → **deny**
   (kill switch).
4. **Soft checkpoint** — at `SOFT_CALLS`, then every 25 → **ask** (or **deny** in
   CI via `COST_GUARD_SOFT_ACTION`).
5. otherwise **allow**.

State is one JSON file per `sessionId` under `COST_GUARD_STATE_DIR`. On
`session-end` the core writes one JSONL record to `COST_GUARD_LOG_DIR`, flags
error/timeout/abort sessions into `wasted-sessions.jsonl`, and optionally POSTs
the record to the collector. Identity (user/gitEmail/host) is captured locally
at session-start because hook payloads carry none.

## Per-platform decision shapes (the only real differences)

| Platform | session id field | pre-tool in | decision out |
|---|---|---|---|
| Claude Code | `session_id` | `tool_name`/`tool_input` | `hookSpecificOutput.permissionDecision` (allow/deny/ask) |
| Copilot | `sessionId` | `toolName`/`toolArgs` | `permissionDecision` (allow/deny/ask) |
| Cursor | `conversation_id` | `tool_name`/`tool_input` | `permission` (+ `agent_message`/`user_message`, camelCase twins) |
| Codex | `session_id` | `tool_name`/`tool_input` | `hookSpecificOutput.permissionDecision` (Claude-compatible) |
| Gemini | `session_id` / `$GEMINI_SESSION_ID` | `tool_name`/`tool_input` | top-level `{decision:"deny",reason,continue:false}`; silent on allow |

## Support tiers (honest)

| Platform | Tier | Notes |
|---|---|---|
| Claude Code | **FULL** | Flagship; loop/streak/ceiling/checkpoint + logging. Failure streak is best-effort (no dedicated tool-failure event → inferred from `tool_response`). |
| GitHub Copilot | **FULL** | The original target; CLI + cloud agent. |
| Cursor | **FULL** | `preToolUse` gate + `postToolUseFailure` + lifecycle. Cloud agents drop `sessionStart`/`sessionEnd` → core bootstraps state lazily on first pre-tool; only the end record is skipped in cloud. `ask` not enforced on `preToolUse` → soft checkpoint degrades to allow. |
| OpenAI Codex | **FULL** (≥ ~v0.117, `features.hooks`) | PreToolUse interception solid for Bash, uneven for apply_patch/MCP. Older Codex → fire-and-forget `notify` only (fallback: launcher/MCP proxy). Finalizes on `Stop` (no SessionEnd). |
| Google Gemini | **FULL** (≥ v0.26.0) | `BeforeTool` gate + `AfterTool` + lifecycle. No `ask` → soft checkpoint degrades to allow. Below v0.26.0 → static allowlists only. |

## Fail policy (preserved from the original)

- **Fail OPEN on the gate**: missing jq / missing core / a slow guard → allow.
  Never brick a session on our account. (Cursor users who want strict
  enforcement can set `failClosed: true` in `.cursor/hooks.json`.)
- The network call happens only on `session-end`, never in the pre-tool hot path.

## Distribution

- **Claude Code**: repo root is itself the plugin (`.claude-plugin/plugin.json`)
  and a single-plugin marketplace (`.claude-plugin/marketplace.json`, plugin
  `source: "./"`). `plugin.json` points `hooks` at
  `./adapters/claude-code/hooks.json`, which references scripts via
  `${CLAUDE_PLUGIN_ROOT}`.
- **Generic repo**: each non-Claude platform installs by copying `core/` +
  `adapters/<platform>/adapter.*` into that platform's hook directory and adding
  the provided wiring file. Adapters resolve the core across layouts
  (`$COST_GUARD_CORE`, bundled `core/`, or repo-relative `../../core`).

## Layout

```
.claude-plugin/{plugin.json, marketplace.json}   # Claude Code plugin + marketplace
core/{guard.sh, guard.ps1}                        # the neutral engine
adapters/<platform>/{adapter.sh, adapter.ps1, wiring}
collector/collector.py                            # unchanged zero-dep collector
tests/                                             # sample payloads + runner
docs/plans/                                        # this doc
```
