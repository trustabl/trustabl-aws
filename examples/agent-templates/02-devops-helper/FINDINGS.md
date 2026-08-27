# 02 — devops-helper

**SDK:** Claude Agent SDK · **Language:** Python

## What the agent does

A deploy helper with three tools: `load_deploy_plan` (restore a cached plan),
`rollout_status` (read rollout state from an internal host), and
`fetch_release_notes` (download notes for a tag).

## The new failure modes

### A. Unsafe deserialization (`pickle.loads`)

`load_deploy_plan` calls `pickle.loads` on a caller-influenced blob. Unpickling
executes any `__reduce__` in the payload, so this is arbitrary code execution at
load time — the same severity class as `eval`, reached through a different sink.

### B. TLS verification disabled (unsafe kwarg *value*)

`rollout_status` passes `verify=False` to `requests.get`, and
`fetch_release_notes` hands `ssl._create_unverified_context()` to `urlopen`.
Both silently accept any certificate, turning an "internal" call into an
MITM-able one.

## Why the current rules stay silent

- **Deserialization:** `has_code_exec_call` matches the bare builtins `eval` /
  `exec` / `compile` only (deliberately — it avoids the `re.compile` false
  positive). `pickle.loads`, `yaml.load`, `marshal.loads` are not modeled.
- **TLS:** the network rules use `call_without_kwarg` — they fire when a kwarg
  (`timeout`) is *missing*. There is no predicate for a kwarg present with an
  *unsafe value*. `verify=False` is a present kwarg with a dangerous value, and
  `timeout=10` is set, so `rollout_status` looks clean to OAI-005.

## Existing findings on this file (observed on a real scan)

- **CSDK-009** (high) fires **twice** — these are Claude Agent SDK tools
  (`@tool` from `claude_agent_sdk`), so the dynamic-URL/SSRF detection is the
  Claude-pack rule, not OAI-018. `rollout_status` (f-string host) and
  `fetch_release_notes` (parameter URL) each trip it.
- The **deserialization** (`pickle.loads`) and **`verify=False`** issues
  themselves: **no finding** — exactly the gap this template documents.

## Candidate rules

- `has_unsafe_deserialization` — bare/attribute callees `pickle.loads`,
  `pickle.load`, `yaml.load` (without `SafeLoader`), `marshal.loads`,
  `dill.loads`. Severity high. New AST predicate (mirrors `has_code_exec_call`).
- `call_with_unsafe_kwarg_value` — a call whose kwarg equals a known-unsafe
  literal: `verify=False` on `requests`/`httpx`, or an argument of
  `ssl._create_unverified_context()`. Generalizes the existing
  `tool_decorator_kwarg_value` idea from decorators to arbitrary calls.
