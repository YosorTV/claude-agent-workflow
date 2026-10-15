"""tracker-mcp - a minimal MCP server that exposes an issue tracker to agents.

Deliberately backed by a single JSON file rather than a real tracker API. The point of this
server is the *shape* of the interface: what an agent is allowed to see, what it is allowed to
change, and where the boundary sits. Swap `Store` for a Jira / Azure DevOps / Linear client and
the tool surface stays the same.

Two rules are encoded here rather than left to the prompt:

1. An agent can move a ticket forward through the declared workflow, and no further. It cannot
   jump a story straight to Done, and it cannot reopen what a human closed.
2. Findings are append-only. An agent may add what it learned; it may not rewrite the record.

Transport: stdio.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

DB_PATH = Path(os.environ.get("TRACKER_DB", Path(__file__).parent / "tracker.json"))

# The only legal transitions. Anything else is a refusal, not an error to work around.
WORKFLOW: dict[str, tuple[str, ...]] = {
    "todo": ("investigating",),
    "investigating": ("ready", "blocked"),
    "ready": ("in_progress",),
    "in_progress": ("in_review", "blocked"),
    "in_review": ("in_progress", "ready_to_merge"),
    "ready_to_merge": (),          # only a human closes a ticket
    "blocked": ("todo", "ready"),
    "done": (),
}


@dataclass
class Store:
    path: Path
    data: dict[str, Any] = field(default_factory=dict)

    def load(self) -> dict[str, Any]:
        if not self.path.exists():
            self.data = {"tickets": {}}
            self.save()
        else:
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        return self.data

    def save(self) -> None:
        self.path.write_text(
            json.dumps(self.data, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    def ticket(self, ticket_id: str) -> dict[str, Any]:
        ticket = self.load()["tickets"].get(ticket_id)
        if ticket is None:
            raise ValueError(f"no such ticket: {ticket_id}")
        return ticket


store = Store(DB_PATH)
mcp = FastMCP("tracker")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@mcp.tool()
def list_tickets(state: str | None = None, assignee: str | None = None) -> list[dict[str, Any]]:
    """List tickets, optionally filtered by workflow state or assignee.

    Returns a compact view: full bodies are fetched one at a time with get_ticket, so that a
    listing never floods an agent's context with the text of forty tickets.
    """
    tickets = store.load()["tickets"]
    out = []
    for tid, t in tickets.items():
        if state and t.get("state") != state:
            continue
        if assignee and t.get("assignee") != assignee:
            continue
        out.append(
            {
                "id": tid,
                "title": t.get("title", ""),
                "state": t.get("state", "todo"),
                "assignee": t.get("assignee"),
                "scope_declared": bool(t.get("scope")),
            }
        )
    return sorted(out, key=lambda t: t["id"])


@mcp.tool()
def get_ticket(ticket_id: str) -> dict[str, Any]:
    """Fetch one ticket in full: description, acceptance criteria, declared scope, findings."""
    return {"id": ticket_id, **store.ticket(ticket_id)}


@mcp.tool()
def transition(ticket_id: str, to_state: str, note: str = "") -> dict[str, Any]:
    """Move a ticket to the next workflow state.

    Refuses any transition not declared in the workflow. `ready_to_merge` and `done` are terminal
    for an agent: closing a ticket is a human decision.
    """
    data = store.load()
    ticket = store.ticket(ticket_id)
    current = ticket.get("state", "todo")
    allowed = WORKFLOW.get(current, ())

    if to_state not in allowed:
        return {
            "ok": False,
            "reason": (
                f"{current} -> {to_state} is not a legal transition. "
                f"From {current} you may move to: {', '.join(allowed) or 'nothing - this is terminal'}."
            ),
        }

    ticket["state"] = to_state
    ticket.setdefault("history", []).append(
        {"at": _now(), "from": current, "to": to_state, "note": note}
    )
    data["tickets"][ticket_id] = ticket
    store.data = data
    store.save()
    return {"ok": True, "id": ticket_id, "state": to_state}


@mcp.tool()
def append_findings(ticket_id: str, markdown: str, author: str = "investigator") -> dict[str, Any]:
    """Append a findings entry to a ticket. Append-only: existing entries are never rewritten."""
    if not markdown.strip():
        return {"ok": False, "reason": "empty findings are not a hand-off"}

    data = store.load()
    ticket = store.ticket(ticket_id)
    entries = ticket.setdefault("findings", [])
    entries.append({"at": _now(), "author": author, "body": markdown})
    data["tickets"][ticket_id] = ticket
    store.data = data
    store.save()
    return {"ok": True, "id": ticket_id, "entries": len(entries)}


@mcp.tool()
def declare_scope(ticket_id: str, globs: list[str], rationale: str = "") -> dict[str, Any]:
    """Record the plan's blast radius: the files and modules a story may touch.

    The planner writes it, the reviewer checks the diff against it. An empty list is rejected:
    'everything' is not a blast radius.
    """
    globs = [g.strip() for g in globs if g.strip()]
    if not globs:
        return {"ok": False, "reason": "an empty scope is not a scope - name the files"}

    data = store.load()
    ticket = store.ticket(ticket_id)
    ticket["scope"] = globs
    ticket.setdefault("history", []).append(
        {"at": _now(), "scope": globs, "rationale": rationale}
    )
    data["tickets"][ticket_id] = ticket
    store.data = data
    store.save()
    return {"ok": True, "id": ticket_id, "scope": globs}


if __name__ == "__main__":
    mcp.run(transport="stdio")
