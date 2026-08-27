# Agent templates — surfacing new failure modes

A corpus of small, realistic AI-agent projects, each written to exhibit a
**failure mode the current Trustabl ruleset does not yet detect**. They are a
gap-analysis backlog: something to scan today (most also trip existing rules),
and a motivating example for the next round of detection rules.

> **These templates are intentionally insecure.** Every file carries a header
> saying so. Do not copy them into a real agent. They exist to be analyzed, not
> run in production.

## Why "new" failure modes

Trustabl already covers a lot — missing timeouts, `eval`/`exec`, subprocess
spawn, SSRF via dynamic URLs, path traversal, missing idempotency keys, default
tracing, and more. Each template below targets something **outside** that set:
a plausible bug an ordinary review misses *and* today's rules stay silent on.

| # | Template | SDK | Uncaught failure mode | Why current rules miss it |
|---|---|---|---|---|
| 01 | [support-ticket-agent](01-support-ticket-agent/) | OpenAI Agents SDK | Secret exfiltration via a tool's **return value** (`os.environ`, `.env`) | No predicate inspects what a tool returns; read-then-return isn't a write/shell/SSRF |
| 02 | [devops-helper](02-devops-helper/) | Claude Agent SDK | **Unsafe deserialization** (`pickle.loads`) + **TLS verification disabled** (`verify=False`) | `has_code_exec_call` is `eval`/`exec`/`compile` only; `call_without_kwarg` checks *missing* kwargs, not an unsafe *value* |
| 03 | [analytics-assistant](03-analytics-assistant/) | OpenAI Agents SDK | **SQL/query injection** — raw query built from a tool arg into `cursor.execute` | No query-flow predicate; SSRF is URL-only |
| 04 | [rag-knowledge-assistant](04-rag-knowledge-assistant/) | OpenAI Agents SDK | **Prompt injection from retrieved content** — untrusted fetched text spliced into the next instructions | No taint/data-flow from tool output into prompt construction |
| 05 | [research-orchestrator](05-research-orchestrator/) | OpenAI Agents SDK | **Handoff/sub-agent cycle** with no depth bound | `agent_is_subagent_of_any` exists but there is no cycle/unbounded-delegation rule |
| 06 | [file-butler-mcp](06-file-butler-mcp/) | MCP server | **Overbroad filesystem walk** from `~`/`/` returned to the model + **unbounded retry** loop | Path rules target traversal of a caller path, not an unbounded root walk; no retry/loop predicate |

## Layout

Each template is a self-contained folder:

```
NN-name/
  <agent or server>.py   # the intentionally-insecure agent
  FINDINGS.md            # what it does, the failure mode, why rules miss it,
                         # and the candidate predicate/rule that would catch it
```

`FINDINGS.md` is the useful artifact: it states which **existing** rules already
fire on the file (so the template is still a valid scan input) and isolates the
**new** failure mode that motivates a future rule.

## Scanning them

From a checkout, point the AWS scanner (or the `trustabl` CLI) at this
directory:

```bash
# whole corpus
TARGET=examples/agent-templates bash scan/trustabl-scan.sh

# one template
trustabl scan examples/agent-templates/03-analytics-assistant --format json
```

Expect findings from the shipped rules on most templates; the point of the
corpus is what the report **does not** yet say. See each `FINDINGS.md`.

### Observed on a reference scan

Scanning the whole corpus against the current rule packs produced 17 findings —
all from *existing* rules, none catching the eight headline failure modes:

| Rule | Sev | Where |
|---|---|---|
| CSDK-009 | high | devops-helper — Claude SDK dynamic-URL/SSRF (×2) |
| MCP-008 | high | file-butler — MCP dynamic-URL/SSRF on `sync_to_backup` |
| OAI-018 | medium | rag-assistant — dynamic URL in `fetch_kb_article` |
| OAI-027 | high | rag-assistant — dynamic-URL tool, no `needs_approval` *(newly shipped)* |
| OAI-112 | low | research-orchestrator — no `max_turns` |
| OAI-201 / OAI-203 | medium | repo — default tracing (OAI-203 = tracing **and** no guidance doc, newly shipped) |
| OAI-202 / CSDK-203 | low | repo — no agent-guidance doc |
| OAI-004 | low | OpenAI tools missing `failure_error_function` (×7) |

The secret-exfil-via-return-value, unsafe deserialization, `verify=False`, SQL
injection, prompt-injection dataflow, handoff cycle, unbounded root walk, and
unbounded retry modes all pass unflagged — the backlog below.

## Suggested next rules (summary)

These are the candidate detections the corpus argues for — a backlog, not a
commitment:

- `tool_returns_env_or_secret_file` — a tool whose return path reads
  `os.environ` / a credentials file (templates 01).
- `has_unsafe_deserialization` — `pickle.loads` / `yaml.load` (unsafe loader) /
  `marshal.loads` on non-literal input (template 02).
- `call_with_unsafe_kwarg_value` — a kwarg set to a known-unsafe literal, e.g.
  `verify=False`, `ssl._create_unverified_context` (template 02).
- `has_raw_sql_from_param` — a parameter interpolated into a SQL string passed to
  `execute`/`executescript`/ORM raw (template 03).
- `tool_output_flows_to_prompt` — retrieved/tool text concatenated into an
  agent's instructions or the next prompt (template 04).
- `agent_handoff_cycle` — a delegation cycle among agents (template 05).
- `tool_walks_unbounded_root` — `os.walk`/`glob` rooted at `~`/`/` with contents
  returned (template 06).
- `has_unbounded_retry` — a `while True` retry around a call with no bound/backoff
  (template 06).
