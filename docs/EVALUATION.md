# Evaluating Trustabl on AWS CodePipeline and CodeCatalyst

This guide covers two things: **trialling Trustabl** to decide whether it earns a
place in your pipeline, and **reading the results** once it runs.

---

## What Trustabl evaluates

Trustabl analyses AI-agent codebases for reliability, safety, and security
defects. It inventories the agents,
tools, subagents, skills and MCP servers in a repository, then evaluates each one
against a rule pack covering ten ecosystems: Claude Agent SDK, OpenAI Agents SDK,
Google ADK, MCP, LangChain, LangGraph, CrewAI, AutoGen AG2, Pydantic AI and
Vercel AI.

It looks for the failure modes ordinary code review misses, for example a tool
that shells out and can be prompt-injected, an agent session with no turn limit,
or an MCP tool that fetches a caller-controlled URL.

### Detector identifiers

`DETECTORS` takes a comma-separated subset of these. Omit it to run them all.

| Identifier | Covers |
|---|---|
| `claude_sdk` | Claude Agent SDK (Python and TypeScript) |
| `claude_skill` | Claude Code skills |
| `openai_sdk` | OpenAI Agents SDK |
| `google_adk` | Google Agent Development Kit |
| `mcp` | Model Context Protocol |
| `langchain` | LangChain and LangGraph |
| `crewai` | CrewAI |
| `autogen` | AutoGen / AG2 |
| `pydantic_ai` | Pydantic AI |
| `vercel_ai` | Vercel AI SDK |
| `openshell` | Shell-invocation tools |

Two things worth noting. `langchain` covers **both** LangChain and LangGraph, so
the list of ten ecosystems above maps to ten identifiers plus `openshell`, which
is a cross-cutting detector rather than an SDK. And a value that isn't on this
list is passed through to the scanner verbatim — restricting to a name that does
not exist gives you a scan with nothing to detect, which looks a lot like a clean
repository. Check the inventory counts in the report before trusting a narrowed
scan.

Rules are versioned separately from the engine and fetched at scan time from a
signed channel, so a scan picks up new detections without upgrading the binary.

---

## Trialling it

**1. Scan without gating first.** Run it in report-only mode on a repo you know
well. You are checking whether the findings are real, not whether the build
passes.

**2. Read the inventory before the findings.** If the tool and agent counts look
wrong, the scan is pointed at the wrong path or your SDK is not being detected.
A score computed over the wrong inventory is meaningless.

**3. Sample five findings and judge them yourself.** Open the files it flags. The
question is not "is this a bug" but "would we have wanted to know". False
positives cost trust; findings you would have fixed anyway are the signal.

**4. Then turn gating on.** Start at a `high` severity threshold so only serious
issues break the build, and tighten once the team trusts the output.

---

## Reading the results

### Readiness score

A number from 0 to 100. **Risk is simply `100 - readiness`.** The score is
weighted across the surfaces found, so a repo with one bad tool out of fifty
scores far better than a repo with one bad tool out of two.

**Do not read the score in isolation.** A high score over an empty inventory
means nothing was analysed, not that the code is safe. Check the tool and agent
counts first.

### Severity

| Severity | Meaning |
|---|---|
| `critical` | Exploitable now, fix before shipping |
| `high` | Serious weakness, fix this sprint |
| `medium` | Real defect, schedule it |
| `low` | Worth improving, not urgent |
| `info` / META | Observations, **not defects** — an opaque agent, an unaudited SDK |

`info` and META signals never fail a build on their own. They exist so the report
is honest about what it could not evaluate.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | No findings at or above medium |
| `1` | Gated — findings crossed a configured threshold |
| `2` | Scanner or I/O error, or no usable rules |

**Exit 1 is a result, not a malfunction.** Exit 2 means the scan did not complete
and the output should not be trusted.

### Output files

| File | Use |
|---|---|
| `trustabl.json` | Full machine-readable result: inventory, findings, scores, rule provenance |
| `trustabl.sarif` | SARIF 2.1.0, for any SARIF viewer or code-scanning surface |

The JSON records `rules_version`, `rules_schema_version` and `rules_origin`, so
you can prove which ruleset produced a given result.

### Triage order

Fix in severity order, but use the **projected scores** in the report to decide
where effort pays off. They estimate the score if you resolved everything at a
given severity, so you can see whether clearing every `low` finding is worth it
or whether two `high` ones dominate the result.

Projections come from the same formula, not a re-scan.

---

## Gating

Any one of these can fail the run.

| Control | Effect |
|---|---|
| default | Fails on any finding at medium or above |
| severity threshold | Fails when the worst finding reaches the level you set |
| risk score threshold | Fails when risk reaches a number you set |
| strict | Lowers the bar to any finding of low or above, **and fails a scan that found no agent surfaces at all** |

A common progression is report-only, then `high`, then `medium` once the backlog
is clear.

---

## What Trustabl does not do

Worth knowing before you evaluate it, so the result is not oversold:

- **It is static analysis.** It reads code, it does not run your agent, so it
  cannot observe what happens at inference time.
- **A finding is a weakness, not a proven exploit.** Severity reflects the shape
  of the risk, not a demonstrated attack.
- **Coverage depends on detection.** If your SDK is not one of the ten supported,
  or your agents are constructed dynamically, they may not appear in the
  inventory. The report states what it parsed and what it skipped — read it.
- **An empty result is not a pass.** If nothing was found, verify the scanned
  path and that your SDK is supported before concluding the repo is clean.
  `STRICT=true` enforces this for you: a scan that discovered no tools, agents,
  subagents or skills exits 1 even with zero findings, on the grounds that a
  mistyped `TARGET` or a moved source tree would otherwise leave the gate green
  indefinitely — and nobody investigates a passing build.

---

## Running it here

Vendor `scan/` plus the config for your platform into your repo, then set
variables on the CodeBuild project or CodeCatalyst workflow:

```yaml
REPORT_ONLY: "true"                  # step 1: artifacts only; scanner errors still fail
SEVERITY_THRESHOLD: high             # step 4: turn gating on
```

Variables are **UPPER_SNAKE**: `SEVERITY_THRESHOLD`, `RISK_SCORE_THRESHOLD`,
`STRICT`, `DETECTORS`, `VERSION`, `REPORT_ONLY`, `SECURITY_HUB`.

Do not use `|| true` around the scan to get report-only behaviour. That also
swallows exit 2 (scanner/I/O failure), and those results must not be trusted.

## Where the results appear

| Surface | What you get |
|---|---|
| **Build log** | The readiness panel |
| **Artifacts** | `trustabl.json`, `trustabl.sarif`, `trustabl-summary.md`, `trustabl.env`, `trustabl.asff.json` |
| **CodeCatalyst Reports tab** | SARIF report, when configured in the workflow |

A gate failure exits non-zero, which fails the CodeBuild action and therefore the
pipeline stage.

`trustabl.env` exposes `TRUSTABL_EXIT_CODE`, `TRUSTABL_READINESS_SCORE`,
`TRUSTABL_RISK_SCORE`, `TRUSTABL_MAX_SEVERITY` and `TRUSTABL_FINDINGS_COUNT`
for downstream steps.

For a trial, set `REPORT_ONLY=true` and run the CodeBuild project on its own
before wiring it into a pipeline. That exercises the same scan without gating
a real stage, while still failing if the scanner itself errors.
