# 06 — file-butler-mcp

**SDK:** MCP server (FastMCP) · **Language:** Python

## What the server does

An MCP server exposing two tools to any connecting client: `search_files` walks
a directory tree (default `~`) and returns matching file contents, and
`sync_to_backup` pushes state to a host, retrying until it succeeds.

## The new failure modes

### A. Overbroad filesystem read surface

`search_files` walks from the user's **home directory** — or `/` if the model
passes that as `root` — and returns file **contents** to the caller. Secrets in
`~/.ssh/`, `~/.aws/credentials`, and stray `.env` files are all reachable. The
path is `expanduser`'d correctly, so there is no traversal bug; the hazard is
that the **root itself is unbounded** and contents flow back over the transport.

### B. Unbounded retry loop

`sync_to_backup` wraps its request in `while True` with a fixed 1-second sleep,
no attempt ceiling, and no backoff. A down host or a bad hostname spins the
handler forever, pinning an MCP worker and hammering the target.

## Why the current rules stay silent

- **Filesystem:** `MCP-005` / `OAI-006` model a *caller-supplied path* flowing
  into I/O **without normalization**. Here the path is normalized
  (`expanduser`), and the issue is the breadth of the root plus returning
  contents — a different shape no predicate captures. `os.walk` is not in any
  callee set.
- **Retry:** the outbound call has `timeout=10`, so `MCP-004` is satisfied.
  There is no loop/retry predicate, so the `while True` around the call is
  invisible. (Contrast the "missing timeout" rules, which assume a *single*
  bounded call.)

## Existing findings on this file

- Possibly none at medium+: `search_files` and `sync_to_backup` have docstrings
  and typed params, the request has a timeout, and the URL host is an f-string
  (so a dynamic-URL/SSRF finding on `sync_to_backup` is plausible, but the two
  headline modes are unflagged).

## Candidate rules

- `tool_walks_unbounded_root` — `os.walk` / `glob.glob` / `Path.rglob` rooted at
  `~`, `expanduser(...)`, `/`, or a bare parameter, with the contents returned.
  Severity high, confidence medium.
- `has_unbounded_retry` — a `while True` (or `for` with no bound) enclosing a
  network/subprocess call with no `break` on an attempt counter and no backoff.
  Severity medium. Both need new AST predicates (a loop-structure walk), so they
  are engine additions rather than rules-only.
