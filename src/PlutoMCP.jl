module PlutoMCP

using Pluto
using JSON3
using UUIDs
using HTTP

include("Tools.jl")
include("MCP.jl")
include("Server.jl")

export serve, connect

end
