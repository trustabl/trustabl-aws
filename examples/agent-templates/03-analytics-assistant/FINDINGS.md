# 03 — analytics-assistant

**SDK:** OpenAI Agents SDK · **Language:** Python

## What the agent does

Answers metric questions over a SQLite database. `revenue_by_region` filters
sales by a region argument; `run_saved_report` runs a report by name.

## The new failure mode: SQL/query injection from a tool argument

Both tools build a SQL string by **interpolating a model-supplied parameter**
and pass it to the driver (`cursor.execute`, `cursor.executescript`). Because
tool arguments are produced by the model from conversation context (which
includes user input and prior tool output), an attacker who shapes that context
controls the query:

- `revenue_by_region("x' UNION SELECT password FROM users --")` exfiltrates
  another table.
- `run_saved_report` uses `executescript`, so an injected `; DROP TABLE ...`
  runs as a second statement.

This is the database analogue of SSRF: a caller-controlled value flows into a
powerful sink. Trustabl models the URL sink (OAI-018/MCP-008) but not the SQL
sink.

## Why the current rules stay silent

There is no query-flow predicate. `has_dynamic_url_call` recognizes a non-literal
*URL*; nothing recognizes a non-literal *SQL string* into `execute`. The
parameter is typed and the tool has a docstring, so tool-definition rules are
satisfied too.

## Existing findings on this file

- Likely **none** at medium+. Both tools are well-formed by the shipped rules'
  standards — that is exactly why the injection slips through.

## Candidate rule

`has_raw_sql_from_param` — a parameter (or an f-string/concatenation containing
one) flowing into `execute` / `executemany` / `executescript` / SQLAlchemy
`text()` / a raw ORM query, without a parameter-binding placeholder (`?`, `%s`,
`:name`). Severity high, confidence ~0.6 (a constant query with a bound param is
safe and must not fire). Needs a new data-flow predicate modeled on the existing
dynamic-URL analysis.
