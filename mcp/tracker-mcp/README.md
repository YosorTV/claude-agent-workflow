# tracker-mcp

A minimal MCP server that exposes an issue tracker to coding agents over stdio.

It is backed by a JSON file on purpose. The interesting part is not the storage - it is that two rules
live in the server rather than in a prompt:

**Transitions are validated.** `WORKFLOW` declares the legal moves. An agent cannot jump a story to
`done`, and it cannot reopen what a human closed. A refusal comes back as a readable reason, not an
exception the agent will try to route around.

**Findings are append-only.** `append_findings` adds an entry. There is no tool to edit or delete one,
so the record of what was known at each step survives.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_tickets(state?, assignee?)` | Compact listing - never dumps ticket bodies into context |
| `get_ticket(ticket_id)` | One ticket in full |
| `transition(ticket_id, to_state, note?)` | Move forward through the declared workflow |
| `append_findings(ticket_id, markdown, author?)` | Append a hand-off document |
| `declare_scope(ticket_id, globs, rationale?)` | Record the plan's blast radius: the files a story may touch |

## Run

```bash
uv sync
cp tracker.example.json tracker.json
uv run python server.py
```

`TRACKER_DB` overrides the database path.

## Wire it up

```json
{
  "mcpServers": {
    "tracker": {
      "command": "uv",
      "args": ["--directory", "/path/to/mcp/tracker-mcp", "run", "python", "server.py"]
    }
  }
}
```

## Replacing the store

`Store` is the only class that touches persistence. Swap it for a Jira, Azure DevOps or Linear client
and every tool above keeps working - including the transition rules, which is the point: workflow
validation belongs on the server side of the boundary, where an agent cannot argue with it.
