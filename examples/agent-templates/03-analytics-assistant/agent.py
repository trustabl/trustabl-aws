# ⚠️ INTENTIONALLY INSECURE — Trustabl example template. Do not use in production.
#
# A business-analytics assistant that answers questions over a metrics database.
# It builds SQL from model-supplied arguments by string interpolation and hands
# the result to the driver — a classic injection sink, reached through a tool.
"""Analytics assistant (OpenAI Agents SDK)."""

import sqlite3

from agents import Agent, Runner, function_tool

_DB = sqlite3.connect("metrics.db", check_same_thread=False)


@function_tool
def revenue_by_region(region: str) -> list[dict]:
    """Return total revenue for a region."""
    # FAILURE MODE (uncaught): `region` comes from the model (chosen from
    # conversation context, including user text) and is interpolated straight
    # into the SQL string. A value like `x' UNION SELECT password FROM users --`
    # reshapes the query. No eval/exec, no shell, no URL — just a parameter
    # flowing into cursor.execute.
    cur = _DB.cursor()
    cur.execute(f"SELECT SUM(amount) FROM sales WHERE region = '{region}'")
    return [{"total": row[0]} for row in cur.fetchall()]


@function_tool
def run_saved_report(name: str) -> list[dict]:
    """Run a named, pre-saved report."""
    # Same sink via executescript — even more dangerous, since it runs multiple
    # statements (so an injected `; DROP TABLE ...` executes).
    cur = _DB.cursor()
    cur.executescript(f"-- report: {name}\nSELECT * FROM reports WHERE name = '{name}';")
    return [dict(zip([c[0] for c in cur.description], row)) for row in cur.fetchall()]


analytics_agent = Agent(
    name="analytics-assistant",
    instructions=(
        "You answer questions about company metrics. Use revenue_by_region for "
        "revenue questions and run_saved_report to run a named report. Always "
        "explain the number you return."
    ),
    tools=[revenue_by_region, run_saved_report],
)


async def main() -> None:
    result = await Runner.run(
        analytics_agent, "What was revenue in the EMEA region last quarter?", max_turns=6
    )
    print(result.final_output)
