const TOOL_TIMEOUT_SECONDS = 60.0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function _get_notebook(session, notebook_id_str)
    nid = try
        UUID(notebook_id_str)
    catch
        throw(ArgumentError("invalid_notebook_id::Invalid notebook ID: '$notebook_id_str'"))
    end
    nb = get(session.notebooks, nid, nothing)
    nb === nothing && throw(KeyError("notebook_not_found::No notebook with id '$notebook_id_str' in the current session"))
    return nb
end

function _get_cell(notebook, cell_id_str)
    cid = try
        UUID(cell_id_str)
    catch
        throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$cell_id_str'"))
    end
    cell = get(notebook.cells_dict, cid, nothing)
    cell === nothing && throw(KeyError("cell_not_found::No cell with id '$cell_id_str' in notebook"))
    return cell
end

function _serialize_output(cell)
    if cell.errored
        body = cell.output.body
        body === nothing && return ""
        body isa String && return body
        body isa Dict && return get(body, "msg", sprint(show, body))
        return sprint(show, body)
    end
    body = cell.output.body
    body === nothing && return ""
    mime = cell.output.mime
    if mime == MIME("text/plain") && body isa String
        return body
    elseif body isa String
        return "[$(string(mime)) output, $(sizeof(body)) bytes]"
    elseif body isa Vector{UInt8}
        return "[$(string(mime)) output, $(length(body)) bytes]"
    else
        return "[$(string(mime)) output]"
    end
end

function _cell_to_dict(cell)
    Dict{String,Any}(
        "cell_id" => string(cell.cell_id),
        "code"    => cell.code,
        "output"  => _serialize_output(cell),
        "errored" => cell.errored,
        "running" => cell.running,
        "queued"  => cell.queued,
    )
end

function _wait_for_cell(cell; timeout=TOOL_TIMEOUT_SECONDS)
    t = time()
    while cell.running || cell.queued
        time() - t > timeout && return false
        sleep(0.05)
    end
    return true
end

function _notify_browser(session, notebook)
    try
        Pluto.send_notebook_changes!(Pluto.ClientRequest(; session, notebook))
    catch
        # Best-effort: no connected clients is fine
    end
end

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

function tool_list_notebooks(session, _args)
    [
        Dict{String,Any}(
            "notebook_id" => string(nb.notebook_id),
            "path"        => nb.path,
            "cell_count"  => length(nb.cell_order),
        )
        for nb in values(session.notebooks)
    ]
end

function tool_get_notebook_state(session, args)
    nb = _get_notebook(session, args["notebook_id"])
    Dict{String,Any}(
        "notebook_id" => string(nb.notebook_id),
        "path"        => nb.path,
        "cells"       => [_cell_to_dict(nb.cells_dict[id]) for id in nb.cell_order],
    )
end

function tool_get_cell(session, args)
    nb   = _get_notebook(session, args["notebook_id"])
    cell = _get_cell(nb, args["cell_id"])
    _cell_to_dict(cell)
end

function tool_set_cell_code(session, args)
    nb        = _get_notebook(session, args["notebook_id"])
    cell      = _get_cell(nb, args["cell_id"])
    code      = args["code"]
    run_after = get(args, "run_after", true)

    cell.code = code

    if run_after
        Pluto.update_save_run!(session, nb, [cell]; run_async=false, save=true)
    else
        nb.topology = Pluto.updated_topology(nb.topology, nb, [cell])
        Pluto.save_notebook(session, nb)
        _notify_browser(session, nb)
    end

    _cell_to_dict(cell)
end

function tool_add_cell(session, args)
    nb            = _get_notebook(session, args["notebook_id"])
    code          = get(args, "code", "")
    after_cell_id = get(args, "after_cell_id", nothing)
    run_after     = get(args, "run_after", true)

    new_cell = Pluto.Cell(; code=string(code))
    nb.cells_dict[new_cell.cell_id] = new_cell

    if after_cell_id === nothing || after_cell_id == ""
        push!(nb.cell_order, new_cell.cell_id)
    else
        target_id  = try UUID(after_cell_id) catch; throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$after_cell_id'")) end
        target_idx = findfirst(==(target_id), nb.cell_order)
        target_idx === nothing && throw(KeyError("cell_not_found::Cell '$after_cell_id' not found in notebook"))
        insert!(nb.cell_order, target_idx + 1, new_cell.cell_id)
    end

    if run_after
        Pluto.update_save_run!(session, nb, [new_cell]; run_async=false, save=true)
    else
        nb.topology = Pluto.updated_topology(nb.topology, nb, [new_cell])
        Pluto.save_notebook(session, nb)
        _notify_browser(session, nb)
    end

    _cell_to_dict(new_cell)
end

function tool_delete_cell(session, args)
    nb   = _get_notebook(session, args["notebook_id"])
    cell = _get_cell(nb, args["cell_id"])

    cell_id_str = string(cell.cell_id)

    idx = findfirst(==(cell.cell_id), nb.cell_order)
    idx !== nothing && deleteat!(nb.cell_order, idx)
    delete!(nb.cells_dict, cell.cell_id)

    # Passing no cells lets run_reactive detect the removed cell and clean up
    Pluto.update_save_run!(session, nb, Pluto.Cell[]; run_async=false, save=true)

    Dict{String,Any}("deleted" => true, "cell_id" => cell_id_str)
end

function tool_run_cell(session, args)
    nb       = _get_notebook(session, args["notebook_id"])
    cell     = _get_cell(nb, args["cell_id"])
    wait_for = get(args, "wait_for_completion", true)

    Pluto.update_save_run!(session, nb, [cell]; run_async=!wait_for, save=true)

    if !wait_for
        # Async: wait up to timeout so we can return current state
        _wait_for_cell(cell; timeout=TOOL_TIMEOUT_SECONDS)
    end

    _cell_to_dict(cell)
end

function tool_run_all_cells(session, args)
    nb       = _get_notebook(session, args["notebook_id"])
    wait_for = get(args, "wait_for_completion", false)

    Pluto.update_save_run!(session, nb, nb.cells; run_async=!wait_for, save=true)

    Dict{String,Any}(
        "notebook_id" => string(nb.notebook_id),
        "status"      => wait_for ? "completed" : "queued",
    )
end

function tool_move_cell(session, args)
    nb            = _get_notebook(session, args["notebook_id"])
    cell          = _get_cell(nb, args["cell_id"])
    after_cell_id = args["after_cell_id"]

    old_idx = findfirst(==(cell.cell_id), nb.cell_order)
    old_idx === nothing && throw(KeyError("cell_not_found::Cell not found in cell_order"))
    deleteat!(nb.cell_order, old_idx)

    if after_cell_id == ""
        insert!(nb.cell_order, 1, cell.cell_id)
    else
        target_id  = try UUID(after_cell_id) catch; throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$after_cell_id'")) end
        new_idx    = findfirst(==(target_id), nb.cell_order)
        new_idx === nothing && throw(KeyError("cell_not_found::Target cell '$after_cell_id' not found"))
        insert!(nb.cell_order, new_idx + 1, cell.cell_id)
    end

    Pluto.save_notebook(session, nb)
    _notify_browser(session, nb)

    _cell_to_dict(cell)
end

# ---------------------------------------------------------------------------
# Dispatch table
# ---------------------------------------------------------------------------

function call_tool(session, name, arguments)
    if name == "list_notebooks"
        tool_list_notebooks(session, arguments)
    elseif name == "get_notebook_state"
        tool_get_notebook_state(session, arguments)
    elseif name == "get_cell"
        tool_get_cell(session, arguments)
    elseif name == "set_cell_code"
        tool_set_cell_code(session, arguments)
    elseif name == "add_cell"
        tool_add_cell(session, arguments)
    elseif name == "delete_cell"
        tool_delete_cell(session, arguments)
    elseif name == "run_cell"
        tool_run_cell(session, arguments)
    elseif name == "run_all_cells"
        tool_run_all_cells(session, arguments)
    elseif name == "move_cell"
        tool_move_cell(session, arguments)
    else
        throw(ArgumentError("unknown_tool::Unknown tool: '$name'"))
    end
end
