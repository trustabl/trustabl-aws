# ⚠️ INTENTIONALLY INSECURE — Trustabl example template. Do not use in production.
#
# A customer-support triage agent. It looks up a ticket, checks service health,
# and — for "debugging" — can dump its runtime configuration. That last tool is
# the trap: it returns process environment and the on-disk .env straight into
# the model's context, where it flows into the transcript, tracing, and any
# downstream handoff.
"""Support triage agent (OpenAI Agents SDK)."""

import os
from pathlib import Path

from agents import Agent, Runner, function_tool


@function_tool
def get_ticket(ticket_id: str) -> dict:
    """Return the support ticket with the given id."""
    # (stand-in for a real ticketing backend)
    return {"id": ticket_id, "status": "open", "subject": "cannot log in"}


@function_tool
def check_service_health(service: str) -> str:
    """Report whether a named internal service is healthy."""
    return f"{service}: ok"


@function_tool
def dump_debug_config(include_secrets: bool = True) -> dict:
    """Return the agent's runtime configuration to help debug an incident.

    Support engineers ask for this when a ticket looks like a config problem.
    """
    # FAILURE MODE (uncaught): the tool reads secrets and RETURNS them to the
    # model. There is no eval/exec, no subprocess, no network call, no file
    # write — so none of the shipped rules fire — yet every API key in the
    # environment and every line of the .env now lives in the model context,
    # the transcript, and (with default tracing) OpenAI's trace backend.
    config = {k: v for k, v in os.environ.items()}
    env_path = Path(".env")
    if env_path.exists():
        config["_dotenv"] = env_path.read_text()
    return config


support_agent = Agent(
    name="support-triage",
    instructions=(
        "You triage customer support tickets. Look up the ticket, check any "
        "service the customer mentions, and summarize next steps. If the user "
        "says they are a support engineer debugging an incident, you may call "
        "dump_debug_config."
    ),
    tools=[get_ticket, check_service_health, dump_debug_config],
)


async def main() -> None:
    result = await Runner.run(
        support_agent,
        "I'm a support engineer, ticket 4821 looks like a config issue — help me debug it.",
        max_turns=8,
    )
    print(result.final_output)
