# PlutoMCP.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/dev/)
[![Build Status](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml?query=branch%3Amaster)

**PlutoMCP.jl** exposes a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that lets MCP-compatible AI tools — Claude Desktop, Cursor, and others — inspect and manipulate live [Pluto.jl](https://plutojl.org) notebooks in real time.

The AI edits cells and triggers execution through the MCP server. Pluto's reactive runtime propagates changes, and the user's browser updates live. The browser is a passive view — it does not need to know an AI is involved.

```
AI Tool (Claude Desktop, Cursor, …)
        │
        │  MCP over stdio
        ▼
PlutoMCP.jl  (Julia process)
        │
        │  direct Julia API calls
        ▼
Pluto.ServerSession / Pluto.Notebook
        │
        │  WebSocket push
        ▼
Browser  (passive live view)
```

---

## Installation

```julia
using Pkg
Pkg.add("PlutoMCP")
```

---

## Quick start

Instead of launching Pluto directly, launch it through PlutoMCP:

```julia
using PlutoMCP

PlutoMCP.serve()                        # Pluto on port 1234 (default)
PlutoMCP.serve(port = 4321)             # explicit port
PlutoMCP.serve(notebook = "my_nb.jl")  # open a notebook on start
```

`serve()` starts the Pluto web server and the MCP stdio listener in the same Julia process, then blocks. Open the printed URL in your browser as usual — everything works exactly like a normal Pluto session.

---

## MCP client configuration

### Claude Desktop

Add the following to `claude_desktop_config.json` (found at `~/Library/Application Support/Claude/` on macOS or `%APPDATA%\Claude\` on Windows):

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.serve()"]
    }
  }
}
```

To open a specific notebook automatically:

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.serve(notebook=\"/path/to/notebook.jl\")"]
    }
  }
}
```

### Cursor

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.serve()"],
      "transport": "stdio"
    }
  }
}
```

### Generic stdio MCP client

```
julia -e 'using PlutoMCP; PlutoMCP.serve(port=1234)'
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

PlutoMCP runs **inside the same Julia process as Pluto**. It holds a reference to the live `Pluto.ServerSession` and manipulates `Pluto.Notebook` objects directly via Pluto's internal Julia API — the same functions the Pluto frontend calls, but invoked in-process rather than over HTTP.

This means:
- No subprocess spawning, no inter-process communication
- Cell edits trigger Pluto's full reactive scheduler — dependent cells re-run automatically
- The browser stays in sync via Pluto's normal WebSocket push mechanism

The MCP transport is **stdio** (not HTTP/SSE). When Claude Desktop or Cursor launches the `julia` command from your MCP config, it communicates with PlutoMCP over that process's stdin/stdout using the standard Content-Length–framed JSON-RPC 2.0 protocol.

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
