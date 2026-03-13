const MCP_PROTOCOL_VERSION = "2024-11-05"
const MCP_SERVER_NAME      = "PlutoMCP"
const MCP_SERVER_VERSION   = "1.0.0"

# ---------------------------------------------------------------------------
# Tool schema definitions
# ---------------------------------------------------------------------------

const MCP_TOOLS = [
    Dict{String,Any}(
        "name"        => "list_notebooks",
        "description" => "List all notebooks currently open in the Pluto session.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(),
            "required"   => String[],
        ),
    ),
    Dict{String,Any}(
        "name"        => "get_notebook_state",
        "description" => "Return a full snapshot of a notebook: all cell IDs, code, and current output/error state.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id" => Dict("type" => "string", "description" => "The notebook UUID."),
            ),
            "required" => ["notebook_id"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "get_cell",
        "description" => "Return the code and output of a single cell.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id" => Dict("type" => "string", "description" => "The notebook UUID."),
                "cell_id"     => Dict("type" => "string", "description" => "The cell UUID."),
            ),
            "required" => ["notebook_id", "cell_id"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "set_cell_code",
        "description" => "Replace the code in a cell. Runs the cell (and reactive dependents) unless run_after is false.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id" => Dict("type" => "string", "description" => "The notebook UUID."),
                "cell_id"     => Dict("type" => "string", "description" => "The cell UUID."),
                "code"        => Dict("type" => "string", "description" => "New cell code."),
                "run_after"   => Dict("type" => "boolean", "description" => "Run the cell after updating. Default: true."),
            ),
            "required" => ["notebook_id", "cell_id", "code"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "add_cell",
        "description" => "Insert a new cell into the notebook, optionally after a specific cell.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id"   => Dict("type" => "string", "description" => "The notebook UUID."),
                "code"          => Dict("type" => "string", "description" => "Initial cell code."),
                "after_cell_id" => Dict("type" => "string", "description" => "Insert after this cell UUID; omit to append at end."),
                "run_after"     => Dict("type" => "boolean", "description" => "Run the new cell after inserting. Default: true."),
            ),
            "required" => ["notebook_id", "code"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "delete_cell",
        "description" => "Delete a cell from the notebook. This is irreversible within the session.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id" => Dict("type" => "string", "description" => "The notebook UUID."),
                "cell_id"     => Dict("type" => "string", "description" => "The cell UUID to delete."),
            ),
            "required" => ["notebook_id", "cell_id"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "run_cell",
        "description" => "Queue a specific cell for execution and optionally wait for it to finish.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id"         => Dict("type" => "string", "description" => "The notebook UUID."),
                "cell_id"             => Dict("type" => "string", "description" => "The cell UUID."),
                "wait_for_completion" => Dict("type" => "boolean", "description" => "Block until the cell finishes. Default: true."),
            ),
            "required" => ["notebook_id", "cell_id"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "run_all_cells",
        "description" => "Re-run all cells in the notebook in dependency order.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id"         => Dict("type" => "string", "description" => "The notebook UUID."),
                "wait_for_completion" => Dict("type" => "boolean", "description" => "Block until all cells finish. Default: false."),
            ),
            "required" => ["notebook_id"],
        ),
    ),
    Dict{String,Any}(
        "name"        => "move_cell",
        "description" => "Reorder a cell relative to another. Pass an empty string for after_cell_id to move to the top.",
        "inputSchema" => Dict{String,Any}(
            "type"       => "object",
            "properties" => Dict{String,Any}(
                "notebook_id"   => Dict("type" => "string", "description" => "The notebook UUID."),
                "cell_id"       => Dict("type" => "string", "description" => "The cell UUID to move."),
                "after_cell_id" => Dict("type" => "string", "description" => "Move after this cell UUID; pass \"\" to move to top."),
            ),
            "required" => ["notebook_id", "cell_id", "after_cell_id"],
        ),
    ),
]

# ---------------------------------------------------------------------------
# JSON-RPC / MCP framing
# ---------------------------------------------------------------------------

function _read_message(io::IO)
    while !eof(io)
        line = readline(io; keep=false)
        isempty(strip(line)) && continue
        return JSON3.read(line, Dict{String,Any})
    end
    return nothing
end

function _write_message(io::IO, msg)
    write(io, JSON3.write(msg))
    write(io, '\n')
    flush(io)
end

# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------

_ok(id, result) = Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "result" => result)

_err(id, code, message) = Dict{String,Any}(
    "jsonrpc" => "2.0",
    "id"      => id,
    "error"   => Dict{String,Any}("code" => code, "message" => message),
)

# ---------------------------------------------------------------------------
# Tool call dispatch
# ---------------------------------------------------------------------------

function _handle_tool_call(session, name, arguments)
    result = call_tool(session, name, arguments)
    Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => JSON3.write(result))],
        "isError" => false,
    )
end

function _safe_handle_tool_call(session, name, arguments)
    try
        _handle_tool_call(session, name, arguments)
    catch e
        raw = sprint(showerror, e)
        # Error format: "error_type::human message"
        error_type, error_msg = if contains(raw, "::")
            parts = split(raw, "::", limit=2)
            string(parts[1]), string(parts[2])
        else
            "tool_error", raw
        end
        Dict{String,Any}(
            "content" => [Dict{String,Any}("type" => "text", "text" => JSON3.write(
                Dict{String,Any}("error" => error_type, "message" => error_msg)
            ))],
            "isError" => true,
        )
    end
end

# ---------------------------------------------------------------------------
# JSON-RPC dispatch (shared by stdio and HTTP/SSE transports)
# ---------------------------------------------------------------------------

function _dispatch_mcp(session, msg::Dict{String,Any})
    method = get(msg, "method", "")
    id     = get(msg, "id", nothing)

    # Notifications have no id and require no response
    id === nothing && return nothing

    if method == "initialize"
        _ok(id, Dict{String,Any}(
            "protocolVersion" => MCP_PROTOCOL_VERSION,
            "capabilities"    => Dict{String,Any}("tools" => Dict{String,Any}()),
            "serverInfo"      => Dict{String,Any}("name" => MCP_SERVER_NAME, "version" => MCP_SERVER_VERSION),
        ))

    elseif method == "tools/list"
        _ok(id, Dict{String,Any}("tools" => MCP_TOOLS))

    elseif method == "tools/call"
        params    = get(msg, "params", Dict{String,Any}())
        name      = get(params, "name", "")
        arguments = get(params, "arguments", Dict{String,Any}())
        result    = _safe_handle_tool_call(session, name, arguments)
        _ok(id, result)

    elseif method == "ping"
        _ok(id, Dict{String,Any}())

    else
        _err(id, -32601, "Method not found: $method")
    end
end

# ---------------------------------------------------------------------------
# stdio loop (used directly by tests and by connect() proxy)
# ---------------------------------------------------------------------------

function run_mcp_server(session, io_in::IO=stdin, io_out::IO=stdout)
    while !eof(io_in)
        msg = _read_message(io_in)
        msg === nothing && break
        resp = _dispatch_mcp(session, msg)
        resp === nothing && continue
        _write_message(io_out, resp)
    end
end
