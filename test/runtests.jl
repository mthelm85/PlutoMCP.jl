using PlutoMCP
using Pluto
using Test
using UUIDs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function make_session_with_notebook(cells...)
    session  = Pluto.ServerSession()
    nb_cells = [Pluto.Cell(; code=c) for c in cells]
    nb       = Pluto.Notebook(collect(nb_cells), tempname() * ".jl")
    session.notebooks[nb.notebook_id] = nb
    session, nb, nb_cells
end

# ---------------------------------------------------------------------------
# Unit tests — no Pluto web server required
# ---------------------------------------------------------------------------

@testset "PlutoMCP.jl" begin

    @testset "list_notebooks" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        result = PlutoMCP.tool_list_notebooks(session, Dict())
        @test length(result) == 1
        @test result[1]["notebook_id"] == string(nb.notebook_id)
        @test result[1]["cell_count"] == 1
    end

    @testset "get_notebook_state" begin
        session, nb, cells = make_session_with_notebook("a = 1", "b = 2")
        args   = Dict("notebook_id" => string(nb.notebook_id))
        result = PlutoMCP.tool_get_notebook_state(session, args)
        @test result["notebook_id"] == string(nb.notebook_id)
        @test length(result["cells"]) == 2
        @test result["cells"][1]["code"] == "a = 1"
        @test result["cells"][2]["code"] == "b = 2"
    end

    @testset "get_cell" begin
        session, nb, cells = make_session_with_notebook("z = 99")
        args   = Dict("notebook_id" => string(nb.notebook_id), "cell_id" => string(cells[1].cell_id))
        result = PlutoMCP.tool_get_cell(session, args)
        @test result["cell_id"] == string(cells[1].cell_id)
        @test result["code"] == "z = 99"
    end

    @testset "error on unknown notebook_id" begin
        session, _, _ = make_session_with_notebook("x = 1")
        fake_id = string(uuid4())
        @test_throws Exception PlutoMCP.tool_get_notebook_state(session,
            Dict("notebook_id" => fake_id))
    end

    @testset "error on unknown cell_id" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        fake_cell_id = string(uuid4())
        @test_throws Exception PlutoMCP.tool_get_cell(session,
            Dict("notebook_id" => string(nb.notebook_id), "cell_id" => fake_cell_id))
    end

    @testset "add_cell appended" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        args = Dict(
            "notebook_id" => string(nb.notebook_id),
            "code"        => "new_var = 42",
            "run_after"   => false,
        )
        result = PlutoMCP.tool_add_cell(session, args)
        @test haskey(result, "cell_id")
        @test result["code"] == "new_var = 42"
        @test length(nb.cell_order) == 2
        @test nb.cell_order[end] == UUID(result["cell_id"])
    end

    @testset "add_cell after_cell_id" begin
        session, nb, cells = make_session_with_notebook("first", "last")
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "code"          => "middle",
            "after_cell_id" => string(cells[1].cell_id),
            "run_after"     => false,
        )
        result = PlutoMCP.tool_add_cell(session, args)
        @test length(nb.cell_order) == 3
        @test nb.cell_order[2] == UUID(result["cell_id"])
    end

    @testset "delete_cell" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = 2")
        args = Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
        )
        result = PlutoMCP.tool_delete_cell(session, args)
        @test result["deleted"] == true
        @test length(nb.cell_order) == 1
        @test !haskey(nb.cells_dict, cells[1].cell_id)
    end

    @testset "move_cell to top" begin
        session, nb, cells = make_session_with_notebook("first", "second", "third")
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "cell_id"       => string(cells[3].cell_id),
            "after_cell_id" => "",
        )
        PlutoMCP.tool_move_cell(session, args)
        @test nb.cell_order[1] == cells[3].cell_id
        @test nb.cell_order[2] == cells[1].cell_id
        @test nb.cell_order[3] == cells[2].cell_id
    end

    @testset "move_cell after target" begin
        session, nb, cells = make_session_with_notebook("first", "second", "third")
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "cell_id"       => string(cells[1].cell_id),
            "after_cell_id" => string(cells[3].cell_id),
        )
        PlutoMCP.tool_move_cell(session, args)
        @test nb.cell_order[1] == cells[2].cell_id
        @test nb.cell_order[2] == cells[3].cell_id
        @test nb.cell_order[3] == cells[1].cell_id
    end

    @testset "_serialize_output plain text" begin
        cell = Pluto.Cell(; code="1 + 1")
        cell.output = Pluto.CellOutput(body="2", mime=MIME("text/plain"))
        @test PlutoMCP._serialize_output(cell) == "2"
    end

    @testset "_serialize_output errored" begin
        cell = Pluto.Cell(; code="error(\"boom\")")
        cell.errored = true
        cell.output  = Pluto.CellOutput(body="boom", mime=MIME("text/plain"))
        @test PlutoMCP._serialize_output(cell) == "boom"
    end

    @testset "_serialize_output HTML" begin
        cell = Pluto.Cell(; code="html\"<b>hi</b>\"")
        cell.output = Pluto.CellOutput(body="<b>hi</b>", mime=MIME("text/html"))
        out = PlutoMCP._serialize_output(cell)
        @test startswith(out, "[text/html output,")
    end

    # ---------------------------------------------------------------------------
    # MCP protocol round-trip tests (no network, no Pluto web server)
    # ---------------------------------------------------------------------------

    @testset "MCP protocol: initialize" begin
        session, nb, _ = make_session_with_notebook("x = 7")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        msg  = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => Dict())
        body = PlutoMCP.JSON3.write(msg)
        write(buf_in, "Content-Length: $(sizeof(body))\r\n\r\n$(body)")
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        seekstart(buf_out)
        header = rstrip(readline(buf_out), '\r')
        readline(buf_out)  # blank line
        n    = parse(Int, split(header, ": ")[2])
        resp = PlutoMCP.JSON3.read(String(read(buf_out, n)), Dict{String,Any})

        @test resp["result"]["protocolVersion"] == PlutoMCP.MCP_PROTOCOL_VERSION
        @test resp["result"]["serverInfo"]["name"] == "PlutoMCP"
    end

    @testset "MCP protocol: tools/list" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        msg  = Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => Dict())
        body = PlutoMCP.JSON3.write(msg)
        write(buf_in, "Content-Length: $(sizeof(body))\r\n\r\n$(body)")
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        seekstart(buf_out)
        header = rstrip(readline(buf_out), '\r')
        readline(buf_out)
        n     = parse(Int, split(header, ": ")[2])
        resp  = PlutoMCP.JSON3.read(String(read(buf_out, n)), Dict{String,Any})
        names = [t["name"] for t in resp["result"]["tools"]]

        @test "list_notebooks"   ∈ names
        @test "get_notebook_state" ∈ names
        @test "set_cell_code"    ∈ names
        @test "add_cell"         ∈ names
        @test "delete_cell"      ∈ names
        @test "run_cell"         ∈ names
        @test "run_all_cells"    ∈ names
        @test "move_cell"        ∈ names
    end

    @testset "MCP protocol: tools/call list_notebooks" begin
        session, nb, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        msg = Dict("jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
            "params" => Dict("name" => "list_notebooks", "arguments" => Dict{String,Any}()))
        body = PlutoMCP.JSON3.write(msg)
        write(buf_in, "Content-Length: $(sizeof(body))\r\n\r\n$(body)")
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        seekstart(buf_out)
        header = rstrip(readline(buf_out), '\r')
        readline(buf_out)
        n    = parse(Int, split(header, ": ")[2])
        resp = PlutoMCP.JSON3.read(String(read(buf_out, n)), Dict{String,Any})

        @test resp["result"]["isError"] == false
        data = PlutoMCP.JSON3.read(resp["result"]["content"][1]["text"])
        @test length(data) == 1
        @test data[1]["notebook_id"] == string(nb.notebook_id)
    end

    @testset "MCP protocol: unknown method returns error" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        msg  = Dict("jsonrpc" => "2.0", "id" => 4, "method" => "nonexistent", "params" => Dict())
        body = PlutoMCP.JSON3.write(msg)
        write(buf_in, "Content-Length: $(sizeof(body))\r\n\r\n$(body)")
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        seekstart(buf_out)
        header = rstrip(readline(buf_out), '\r')
        readline(buf_out)
        n    = parse(Int, split(header, ": ")[2])
        resp = PlutoMCP.JSON3.read(String(read(buf_out, n)), Dict{String,Any})

        @test haskey(resp, "error")
        @test resp["error"]["code"] == -32601
    end

    # ---------------------------------------------------------------------------
    # Integration test — real Pluto session, Julia API only (no MCP stdio)
    # ---------------------------------------------------------------------------

    @testset "Integration: set_cell_code triggers reactivity" begin
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        @test isfile(fixture)

        # Work on a temp copy so the fixture is never mutated by Pluto's auto-save
        tmp = tempname() * ".jl"
        cp(fixture, tmp)

        session    = Pluto.ServerSession()
        pluto_task = @async Pluto.run!(session)
        sleep(3.0)

        nb = Pluto.SessionActions.open(session, tmp; run_async=false)

        cell_x_id = "11111111-1111-1111-1111-111111111111"
        cell_y_id = "22222222-2222-2222-2222-222222222222"

        # After open, cells should have run: x=6, y=6*7=42
        result_y = PlutoMCP.tool_get_cell(session,
            Dict("notebook_id" => string(nb.notebook_id), "cell_id" => cell_y_id))
        @test result_y["output"] == "42"

        # Change x; Pluto reactivity re-evaluates y = 10 * 7 = 70
        PlutoMCP.tool_set_cell_code(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => cell_x_id,
            "code"        => "x = 10",
            "run_after"   => true,
        ))

        result_y2 = PlutoMCP.tool_get_cell(session,
            Dict("notebook_id" => string(nb.notebook_id), "cell_id" => cell_y_id))
        @test result_y2["output"] == "70"

        # Teardown — shut down notebook; let the async Pluto task finish on its own
        Pluto.SessionActions.shutdown(session, nb; async=false, verbose=false)
        try; schedule(pluto_task, InterruptException(); error=true); catch; end
    end

end
