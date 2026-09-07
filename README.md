# PlutoMCP.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/dev/)
[![Build Status](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml?query=branch%3Amain)

**PlutoMCP.jl** exposes a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that lets MCP-compatible AI tools — Claude Desktop, Cursor, and others — inspect and manipulate live [Pluto.jl](https://plutojl.org) notebooks in real time.

```
You (terminal)            AI Tool (Claude Desktop, …)
      │                             │
      │ PlutoMCP.serve()            │  stdio → auto-proxies to bridge
      ▼                             ▼
PlutoMCP bridge  ◄────────── connect() detects :2346 and proxies
      │                   OR connects directly via HTTP/SSE
      │  direct Julia API calls
      ▼
Pluto.ServerSession / Pluto.Notebook  (port 1234)
      │
      │  WebSocket push
      ▼
Browser  (live view — notebooks you open here are visible to AI tools)
```

You start the bridge once when you want Claude to have access. It starts a fresh Pluto session; open notebooks through the Pluto browser UI that `serve()` prints. Claude Desktop configured with `connect()` (stdio) **automatically detects the running bridge** and proxies through it — no reconfiguration needed.

---

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/mthelm85/PlutoMCP.jl")
```

---

## Quick start

### Step 1 — Start the bridge (whenever you want Claude access)

```julia
using PlutoMCP

PlutoMCP.serve()                              # Pluto on :1234, MCP bridge on :2346
PlutoMCP.serve(pluto_port=4321)              # custom Pluto port
PlutoMCP.serve(notebook="my_nb.jl")         # open a notebook on start
PlutoMCP.serve(pluto_port=1234, mcp_port=3000)  # custom MCP port
```

`serve()` starts Pluto in the background and blocks, running the MCP HTTP/SSE server. Open the printed Pluto URL in your browser as usual. **Any notebooks you open in the browser are immediately visible to Claude.**

> **`require_secret_for_access`:** forwarded to Pluto `Options` (default `true`). Pass `false` to open
> `http://localhost:PORT/` without a `?secret=` URL — useful for MCP clients that cannot navigate to a
> secret URL, or over a trusted SSH port-forward.
>
> :warning: **The secret is Pluto's only access control.** With `require_secret_for_access=false`, anything
> that can reach the port can execute arbitrary Julia code as you — including other users of a shared
> machine. Only turn it off on a single-user machine or a trusted port-forward.

> **Important**: open your notebooks through the Pluto UI started by `serve()`, not through a separately-started `Pluto.run()`. The MCP bridge owns its own Pluto session; notebooks from other Pluto processes are not shared.

### Step 2 — Configure your MCP client (one-time)

#### Claude Desktop — stdio

`claude_desktop_config.json` supports **stdio servers only** (`command` / `args` / `env`).
It has no `url` field, so this is the way to wire up Claude Desktop:

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.connect()"]
    }
  }
}
```

`connect()` automatically detects whether a `PlutoMCP.serve()` bridge is running:

- **Bridge running** (recommended): proxies all tool calls through the bridge, so Claude sees the
  live Pluto session and any notebooks you have open in your browser.
- **No bridge**: starts its own isolated Pluto session lazily on the first tool call.

> **Startup cost.** Claude Desktop launches this process every time it starts, and it must load
> Julia and Pluto before it can answer the MCP handshake — roughly **13 s**, and about **800 MB**
> resident while idle. No Pluto *server* is started until you actually call a tool, but the
> process itself is always there. If that bothers you, use the `mcp-remote` setup below and start
> the bridge only when you want it.

#### Claude Desktop — HTTP via `mcp-remote`

Claude Desktop cannot talk to `http://localhost:2346/sse` directly. Its config file is stdio-only,
and custom connectors (Settings → Connectors) reach the server from Anthropic's cloud, so they
require a public HTTPS endpoint — a localhost address is unreachable that way.

To use the HTTP bridge, bridge stdio to it with [`mcp-remote`](https://www.npmjs.com/package/mcp-remote):

```json
{
  "mcpServers": {
    "pluto": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:2346/sse"]
    }
  }
}
```

This spawns a small Node process (~38 MB) instead of a Julia one, and starts no Pluto session of
its own — all tool calls go to the `serve()` bridge. If the bridge is not running, the server
fails to connect and its tools are simply unavailable until you start it.

#### Claude Code — HTTP (native)

Claude Code speaks HTTP/SSE directly, so it needs **no local process at all**:

```bash
claude mcp add --transport sse pluto http://localhost:2346/sse
```

Nothing runs when the bridge is down; Claude Code reports the server as failed to connect and
everything else keeps working. Start `serve()` and the tools appear.

#### Cursor — HTTP

```json
{
  "mcpServers": {
    "pluto": {
      "url": "http://localhost:2346/sse"
    }
  }
}
```

---

## Available MCP tools

| Tool | Description |
|---|---|
| `list_notebooks` | List all notebooks open in the session |
| `get_notebook_state` | Full snapshot of a notebook — all cells, code, and output |
| `get_cell` | Code and output of a single cell |
| `set_cell_code` | Replace a cell's code; optionally run it (default: yes) |
| `add_cell` | Insert a new cell, optionally after a specific cell |
| `delete_cell` | Delete a cell (irreversible within the session) |
| `run_cell` | Queue a cell for execution, optionally waiting for the result |
| `run_all_cells` | Re-run all cells in dependency order |
| `move_cell` | Reorder a cell relative to another |

### Tool details

#### `list_notebooks`

No inputs. Returns an array of notebook objects:

```json
[
  {
    "notebook_id": "abc123",
    "path": "/home/user/analysis.jl",
    "cell_count": 12
  }
]
```

#### `get_notebook_state`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |

Returns the full notebook state including all cells.

#### `get_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID |

Returns a single cell object:

```json
{
  "cell_id": "cell-uuid",
  "code": "x = 1 + 1",
  "output": "2",
  "errored": false,
  "running": false,
  "queued": false
}
```

#### `set_cell_code`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `cell_id` | string | yes | — | Cell UUID |
| `code` | string | yes | — | New cell code |
| `run_after` | boolean | no | `true` | Run the cell (and reactive dependents) after updating |

#### `add_cell`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `code` | string | yes | — | Initial cell code |
| `after_cell_id` | string | no | — | Insert after this cell; omit to append at end |
| `run_after` | boolean | no | `true` | Run the new cell after inserting |

#### `delete_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID to delete |

This is irreversible within the session.

#### `run_cell`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `cell_id` | string | yes | — | Cell UUID |
| `wait_for_completion` | boolean | no | `true` | Block until the cell finishes |

#### `run_all_cells`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `wait_for_completion` | boolean | no | `false` | Block until all cells finish (can be slow) |

#### `move_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID to move |
| `after_cell_id` | string | yes | Move after this cell UUID; pass `""` to move to the top |

### Error responses

When a tool call fails, the result has `"isError": true` and a structured body:

```json
{
  "error": "notebook_not_found",
  "message": "No notebook with id 'abc123' in the current session"
}
```

---

## How it works

PlutoMCP runs **inside the same Julia process as Pluto**. It holds a reference to the live `Pluto.ServerSession` and manipulates `Pluto.Notebook` objects directly via Pluto's internal Julia API — the same functions the Pluto frontend calls, but invoked in-process.

This means:
- Cell edits trigger Pluto's full reactive scheduler — dependent cells re-run automatically
- The browser stays in sync via Pluto's normal WebSocket push mechanism

The MCP transport is **HTTP/SSE** (Server-Sent Events). The bridge exposes three endpoints:

| Endpoint | Purpose |
|---|---|
| `GET /sse` | Establishes the SSE stream; returns a `sessionId` |
| `POST /message?sessionId=...` | Receives JSON-RPC 2.0 requests |
| `GET /health` | Returns `ok` (used by `connect()` to probe the bridge) |

The `connect()` stdio server reads and writes newline-delimited JSON-RPC 2.0 on stdin/stdout, dispatching MCP calls directly without going through the HTTP/SSE bridge. It starts its own Pluto *session* lazily on first tool call — but `using PlutoMCP` loads Pluto at import, so the process still takes ~13 s to answer the initial handshake and holds ~800 MB while idle. When a `serve()` bridge is already running, `connect()` proxies to it instead of starting a second session.

---

## Cell output serialization

MCP tool results are plain text, so rich cell outputs are serialized as follows:

| Output type | Serialized as |
|---|---|
| `text/plain` | the text directly |
| `text/html`, etc. | `[text/html output, 1.2KB]` |
| Binary (images, etc.) | `[image/png output, 48KB]` |
| Error | the error message string; `"errored": true` |
| No output | empty string |

---

## License

MIT
