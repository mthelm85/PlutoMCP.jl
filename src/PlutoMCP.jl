module PlutoMCP

using JSON3
using UUIDs
using HTTP
using Pluto

include("Tools.jl")
include("MCP.jl")
include("Server.jl")

export serve, connect

end
