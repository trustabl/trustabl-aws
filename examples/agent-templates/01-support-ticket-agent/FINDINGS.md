# 01 — support-ticket-agent

**SDK:** OpenAI Agents SDK · **Language:** Python

## What the agent does

A support-triage agent with three tools: `get_ticket`, `check_service_health`,
and `dump_debug_config`. The first two are benign. `dump_debug_config` exists so
a "support engineer" can inspect runtime config during an incident — and the
model can be talked into calling it.

## The new failure mode: secret exfiltration via return value

`dump_debug_config` reads `os.environ` and the on-disk `.env` and **returns them
to the model**. The secrets then live in:

- the model context and the visible transcript,
- OpenAI's hosted tracing backend (if default tracing is on — see OAI-201),
- any handoff target that receives the conversation.

There is no exploit primitive in the classic sense: no `eval`, no `subprocess`,
no outbound request, no file write. The leak is entirely in the tool's **return
path**.

## Why the current rules stay silent

Every shipped tool-body predicate keys on a *call*: `has_shell_call`,
`has_code_exec_call`, `has_write_call`, `has_dynamic_url_call`,
`call_without_kwarg`. None of them model **what a tool returns**. Reading
`os.environ` and returning it is not a write, not a network call, and not code
execution, so the tool trips none of them. `has_dynamic_url_call` would catch a
tool that *sends* secrets somewhere; here the model itself is the exfiltration
channel.

## Existing findings on this file (so it's still a valid scan input)

- Likely **none** at medium+. `get_ticket` / `check_service_health` /
  `dump_debug_config` all have docstrings, typed params, and no flagged calls.
  That silence is the point.

## Candidate rule

`tool_returns_env_or_secret_file` — flag a tool whose return value is derived
from `os.environ`, `os.getenv` over a broad set, or a read of a
credentials/secret file (`.env`, `~/.aws/credentials`, `id_rsa`, `*_key`,
`*.pem`). Severity high, confidence medium (a tool may legitimately return a
single non-secret env value, so scope to bulk `os.environ` copies and known
secret paths). Needs a new return-value-flow predicate (`tool_return_reads`),
which is an engine change, not a rules-only addition.
