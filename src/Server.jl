"""
    serve(; port=1234, notebook=nothing, launch_browser=true)

Start a Pluto server and expose it via an MCP stdio interface.

- `port`: Port for the Pluto web UI (default: 1234).
- `notebook`: Optional path to a `.jl` notebook file to open on start.
- `launch_browser`: Whether to open the system browser automatically (default: true).

## MCP client configuration (Claude Desktop)

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

## Cursor

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

## Generic stdio MCP client

```
julia -e 'using PlutoMCP; PlutoMCP.serve(port=1234)'
```
"""
function serve(; port=1234, notebook=nothing, launch_browser=true)
    options = Pluto.Configuration.from_flat_kwargs(;
        port           = port,
        launch_browser = launch_browser,
    )
    session = Pluto.ServerSession(; options)

    if notebook !== nothing
        Pluto.SessionActions.open(session, notebook; run_async=true)
    end

    # Start Pluto HTTP server in the background; errors go to stderr
    @async try
        Pluto.run!(session)
    catch e
        @error "Pluto server error" exception = (e, catch_backtrace())
    end

    # Brief pause so the Pluto server is up before we start accepting MCP requests
    sleep(1.0)

    # MCP stdio loop — blocks until stdin is closed (i.e. the MCP client disconnects)
    run_mcp_server(session)
end
