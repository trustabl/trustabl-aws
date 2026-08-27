# 05 — research-orchestrator

**SDK:** OpenAI Agents SDK · **Language:** Python

## What the agent does

A two-agent research loop. The `orchestrator` researches and drafts, then hands
off to the `critic`; the `critic` can hand the draft **back** to the
orchestrator for another pass. `Runner.run` is called with no `max_turns`.

## The new failure mode: an unbounded delegation cycle

The handoff graph contains a cycle: `orchestrator → critic → orchestrator`. If
the two agents never converge (the critic keeps asking for "more thorough"),
control ping-pongs between them. With no `max_turns` on the run and no
convergence guarantee, this consumes the token and wall-clock budget without a
ceiling — a reliability and cost failure, and a denial-of-wallet risk.

## Why the current rules stay silent

- `agent_is_subagent_of_any` exists as a predicate, but there is **no rule that
  detects a cycle** in the handoff graph — only membership in a delegation tree.
- `OAI-112` flags a missing `max_turns`, but it is resolved **per agent by its
  own same-file `Runner.run` call**. Here the run targets the orchestrator; the
  cycle risk comes from the *pair*, which no single-agent rule reasons about.

The individual pieces look ordinary: two normal agents, a `web_search` tool with
a docstring. The hazard is the shape of the graph plus the missing bound.

## Existing findings on this file

- `OAI-112` may fire on the `orchestrator` (its `Runner.run` sets no
  `max_turns`) — a partial signal.
- The **cycle** itself: no finding.

## Candidate rule

`agent_handoff_cycle` — a repo/agent-scope rule that walks the resolved handoff
graph and fires when it finds a cycle (A reachable from A) that is not bounded by
a `max_turns` on the entry run. Severity medium, confidence medium (a cycle with
a tight `max_turns` is a legitimate iterate-until-approved pattern, so pair the
cycle detection with the missing-bound condition). Needs graph reachability over
`HandoffRefs` in the inventory — an engine addition, but a self-contained one.
