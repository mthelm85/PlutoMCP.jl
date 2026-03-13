# ---------------------------------------------------------------------------
# URL query-string parser (avoids HTTP.URIs API uncertainty)
# ---------------------------------------------------------------------------

function _query_params(target::String)
    d   = Dict{String,String}()
    idx = findfirst('?', target)
    idx === nothing && return d
    for pair in split(target[idx+1:end], '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 && (d[kv[1]] = kv[2])
    end
    d
end

# ---------------------------------------------------------------------------
# SSE session state
# ---------------------------------------------------------------------------

const _SSE_SESSIONS      = Dict{String,Channel{String}}()
const _SSE_SESSIONS_LOCK = ReentrantLock()

# ---------------------------------------------------------------------------
# Internal HTTP/SSE endpoint handlers
# ---------------------------------------------------------------------------

function _handle_sse(http::HTTP.Stream)
    sid = string(uuid4())
    ch  = Channel{String}(64)

    lock(_SSE_SESSIONS_LOCK) do
        _SSE_SESSIONS[sid] = ch
    end

    HTTP.setheader(http, "Content-Type"  => "text/event-stream")
    HTTP.setheader(http, "Cache-Control" => "no-cache")
    HTTP.setheader(http, "Connection"    => "keep-alive")
    HTTP.startwrite(http)

    # Tell the client where to POST messages
    write(http, "event: endpoint\ndata: /message?sessionId=$sid\n\n")
    flush(http)

    # Background keepalive so proxies don't close idle connections
    keepalive = @async while isopen(ch)
        sleep(15)
        try
            write(http, ": keepalive\n\n")
            flush(http)
        catch
            break
        end
    end

    try
        for msg_json in ch
            write(http, "event: message\ndata: $msg_json\n\n")
            flush(http)
        end
    catch
        # Client disconnected
    finally
        lock(_SSE_SESSIONS_LOCK) do
            delete!(_SSE_SESSIONS, sid)
        end
        isopen(ch) && close(ch)
        try schedule(keepalive, InterruptException(); error=true) catch end
    end
end

function _handle_post(http::HTTP.Stream, pluto_session)
    params = _query_params(http.message.target)
    sid    = get(params, "sessionId", "")

    ch = lock(_SSE_SESSIONS_LOCK) do
        get(_SSE_SESSIONS, sid, nothing)
    end

    if ch === nothing
        HTTP.setstatus(http, 404)
        HTTP.startwrite(http)
        write(http, """{"error":"Session not found"}""")
        return
    end

    body = String(read(http))
    msg  = try
        JSON3.read(body, Dict{String,Any})
    catch
        HTTP.setstatus(http, 400)
        HTTP.startwrite(http)
        write(http, """{"error":"Invalid JSON"}""")
        return
    end

    resp = _dispatch_mcp(pluto_session, msg)
    isopen(ch) && resp !== nothing && put!(ch, JSON3.write(resp))

    HTTP.setstatus(http, 202)
    HTTP.startwrite(http)
end

# ---------------------------------------------------------------------------
# HTTP/SSE MCP server
# ---------------------------------------------------------------------------

function _run_http_mcp_server(pluto_session, port::Int)
    function handler(http::HTTP.Stream)
        # CORS on every response
        HTTP.setheader(http, "Access-Control-Allow-Origin" => "*")

        method = http.message.method
        target = http.message.target

        if method == "OPTIONS"
            HTTP.setheader(http, "Access-Control-Allow-Methods" => "GET, POST, OPTIONS")
            HTTP.setheader(http, "Access-Control-Allow-Headers" => "Content-Type")
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)

        elseif method == "GET" && startswith(target, "/sse")
            _handle_sse(http)

        elseif method == "POST" && startswith(target, "/message")
            _handle_post(http, pluto_session)

        elseif method == "GET" && target == "/health"
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            write(http, "ok")

        else
            HTTP.setstatus(http, 404)
            HTTP.startwrite(http)
        end
    end

    HTTP.serve(handler, "127.0.0.1", port; stream=true, verbose=false)
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    serve(; pluto_port=1234, mcp_port=2346, notebook=nothing, launch_browser=true)

Start a Pluto server and expose it via an MCP HTTP/SSE interface.

## Workflow

Run this once (e.g. from a terminal or startup script) when you want Claude to have access:

```julia
using PlutoMCP
PlutoMCP.serve()          # Pluto on :1234, MCP bridge on :2346
```

Then configure your MCP client **once**:

### Claude Desktop — HTTP (preferred)

```json
{
  "mcpServers": {
    "pluto": { "url": "http://localhost:2346/sse" }
  }
}
```

### Claude Desktop — stdio fallback (if HTTP MCP not yet supported)

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

The bridge must be running before an HTTP/SSE client connects.
For stdio clients, use `connect()` instead — it starts Pluto lazily on first use.
"""
function serve(; pluto_port=1234, mcp_port=2346, notebook=nothing, launch_browser=true)
    @eval using Pluto
    # `Pluto` binding was added in the new world age; define a helper there so it
    # can resolve the name, then call it via invokelatest.
    @eval function __pluto_serve_init__(pluto_port, launch_browser, notebook)
        opts = Pluto.Configuration.from_flat_kwargs(
            port           = pluto_port,
            launch_browser = launch_browser,
        )
        sess = Pluto.ServerSession(; options = opts)
        if notebook !== nothing
            Pluto.SessionActions.open(sess, notebook; run_async = true)
        end
        @async try
            Pluto.run!(sess)
        catch e
            @error "Pluto server error" exception=(e, catch_backtrace())
        end
        sleep(1.0)  # brief pause so Pluto is up before MCP clients connect
        sess
    end
    pluto_session = Base.invokelatest(__pluto_serve_init__, pluto_port, launch_browser, notebook)

    @info "PlutoMCP ready"
    @info "  Pluto UI       → http://localhost:$pluto_port"
    @info "  MCP bridge     → http://localhost:$mcp_port/sse"
    @info "  stdio fallback → julia -e 'using PlutoMCP; PlutoMCP.connect(mcp_port=$mcp_port)'"

    _run_http_mcp_server(pluto_session, mcp_port)
end

# ---------------------------------------------------------------------------
# Public API (continued)
# ---------------------------------------------------------------------------

"""
    connect(; pluto_port=1234)

Self-contained stdio MCP server for clients that require a stdio subprocess
(e.g. Claude Desktop).

Responds to `initialize`, `tools/list`, and `ping` instantly without loading
Pluto.  Pluto is started lazily on the **first `tools/call`**, so Claude Desktop
starts up immediately and Pluto only runs when you actually use a PlutoMCP tool.

## Claude Desktop config

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
"""
function connect(; pluto_port=1234)
    pluto_session = Ref{Any}(nothing)

    function _get_session()
        if pluto_session[] === nothing
            @info "PlutoMCP: first tool call — starting Pluto (this may take ~30 s)…"
            @eval using Pluto
            @eval function __pluto_connect_init__(pluto_port)
                opts = Pluto.Configuration.from_flat_kwargs(
                    port           = pluto_port,
                    launch_browser = false,
                )
                sess = Pluto.ServerSession(; options = opts)
                @async try
                    Pluto.run!(sess)
                catch e
                    @error "Pluto server error" exception=(e, catch_backtrace())
                end
                sleep(1.0)
                sess
            end
            pluto_session[] = Base.invokelatest(__pluto_connect_init__, pluto_port)
        end
        pluto_session[]
    end

    while !eof(stdin)
        msg = _read_message(stdin)
        msg === nothing && break

        method = get(msg, "method", "")
        id     = get(msg, "id", nothing)

        # Notifications (no id) require no response
        id === nothing && continue

        sess = method == "tools/call" ? _get_session() : nothing
        resp = _dispatch_mcp(sess, msg)
        resp === nothing && continue
        _write_message(stdout, resp)
    end
end
