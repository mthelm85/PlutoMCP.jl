module PlutoMCP

using Pluto
using JSON3
using UUIDs

include("Tools.jl")
include("MCP.jl")
include("Server.jl")

export serve

end
