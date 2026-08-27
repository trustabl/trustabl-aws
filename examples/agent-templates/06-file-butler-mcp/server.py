# ⚠️ INTENTIONALLY INSECURE — Trustabl example template. Do not use in production.
#
# An MCP "file butler" server. It offers a search tool that walks the user's
# home directory (and can be pointed at /) and returns matching file contents,
# and a sync tool that retries forever with no backoff. Two uncaught modes:
# an unbounded filesystem read surface, and an unbounded retry loop.
"""File-butler MCP server."""

import os
import time

import requests
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("file-butler")


@mcp.tool()
def search_files(needle: str, root: str = "~") -> list[dict]:
    """Search files under `root` (default: home) for `needle` and return matches."""
    # FAILURE MODE (uncaught): the walk is rooted at the user's home directory
    # (or `/` if the model passes it) and returns file CONTENTS to the caller.
    # This is a broad read/exfiltration surface — ~/.ssh/id_rsa, ~/.aws/
    # credentials, .env files all become reachable. It is NOT a traversal of a
    # single caller path (what MCP-005 models); `root` is normalized fine, the
    # danger is that the *root itself* is unbounded.
    base = os.path.expanduser(root)
    matches = []
    for dirpath, _dirs, files in os.walk(base):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                with open(path, "r", errors="ignore") as f:
                    text = f.read()
            except OSError:
                continue
            if needle in text:
                matches.append({"path": path, "excerpt": text[:200]})
    return matches


@mcp.tool()
def sync_to_backup(host: str) -> str:
    """Push local state to a backup host, retrying until it succeeds."""
    # FAILURE MODE (uncaught): a `while True` retry with no attempt ceiling and
    # no backoff. A backup host that is down (or a bad hostname) spins this
    # forever, pegging a worker and hammering the target. Note the request has a
    # timeout, so the network timeout rule is satisfied — the unbounded loop
    # around it is the problem.
    while True:
        resp = requests.post(f"https://{host}/backup", timeout=10)
        if resp.status_code == 200:
            return "ok"
        time.sleep(1)  # fixed 1s sleep, no backoff, no max attempts


if __name__ == "__main__":
    mcp.run()
