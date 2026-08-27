# ⚠️ INTENTIONALLY INSECURE — Trustabl example template. Do not use in production.
#
# A devops helper agent. It restores a previously-saved "deploy plan" from a
# cache and fetches a rollout status from an internal endpoint. Two quiet traps:
# the cache is loaded with pickle (arbitrary code execution on load), and the
# status fetch disables TLS verification.
"""Devops helper agent (Claude Agent SDK)."""

import pickle
import ssl
import urllib.request

import requests
from claude_agent_sdk import tool


@tool
def load_deploy_plan(plan_blob: bytes) -> dict:
    """Restore a previously-saved deploy plan from its cached blob."""
    # FAILURE MODE (uncaught): pickle.loads on caller-influenced bytes is
    # arbitrary code execution at load time — a __reduce__ payload runs during
    # unpickling. The shipped code-exec rule only matches eval/exec/compile, so
    # this deserialization sink is invisible.
    plan = pickle.loads(plan_blob)
    return {"steps": plan.get("steps", [])}


@tool
def rollout_status(host: str) -> str:
    """Fetch the rollout status JSON from an internal deploy host."""
    # FAILURE MODE (uncaught): verify=False disables certificate validation, so
    # the "internal" call is trivially MITM-able. The timeout is present, so the
    # network rules are satisfied; nothing flags the disabled verification.
    resp = requests.get(f"https://{host}/rollout", timeout=10, verify=False)
    return resp.text


@tool
def fetch_release_notes(url: str) -> str:
    """Download release notes for a version tag."""
    # A second flavor of the same value-level gap: an unverified SSL context
    # handed to urlopen.
    ctx = ssl._create_unverified_context()
    with urllib.request.urlopen(url, timeout=10, context=ctx) as r:
        return r.read().decode()


# The Claude Agent SDK wires these tools into an AgentDefinition / query() run
# elsewhere; the tool definitions above are what a scan discovers.
