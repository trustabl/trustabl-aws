# ⚠️ INTENTIONALLY INSECURE — Trustabl example template. Do not use in production.
#
# A multi-agent research setup that can delegate in a cycle: the orchestrator
# hands off to a critic, the critic hands back to the orchestrator, and neither
# the handoff graph nor the run has a depth/turn bound. A stubborn task can
# ping-pong until the token budget is gone.
"""Research orchestrator with a delegation cycle (OpenAI Agents SDK)."""

from agents import Agent, Runner, function_tool


@function_tool
def web_search(query: str) -> str:
    """Search the web and return the top result snippet."""
    return f"(results for {query})"


# The critic reviews a draft and can send it back for another pass.
critic = Agent(
    name="critic",
    instructions=(
        "You critique a research draft. If it is not thorough enough, hand back "
        "to the orchestrator for another pass. Otherwise, approve it."
    ),
    tools=[],
)

orchestrator = Agent(
    name="orchestrator",
    instructions=(
        "You research a topic, write a draft, and hand off to the critic. If the "
        "critic returns it, revise and hand off again until the critic approves."
    ),
    tools=[web_search],
    handoffs=[critic],
)

# FAILURE MODE (uncaught): the handoff graph is a cycle — orchestrator -> critic
# -> orchestrator. Combined with a run that sets no max_turns, a disagreement
# between the two agents loops indefinitely, burning tokens and wall-clock with
# no ceiling.
critic.handoffs = [orchestrator]


async def main() -> None:
    # No max_turns: nothing bounds the orchestrator<->critic ping-pong.
    result = await Runner.run(orchestrator, "Research the history of the astrolabe.")
    print(result.final_output)
