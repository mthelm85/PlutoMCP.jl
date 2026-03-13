using PlutoMCP
using Documenter

DocMeta.setdocmeta!(PlutoMCP, :DocTestSetup, :(using PlutoMCP); recursive=true)

makedocs(;
    modules=[PlutoMCP],
    authors="Matt Helm <mthelm85@gmail.com> and contributors",
    sitename="PlutoMCP.jl",
    format=Documenter.HTML(;
        canonical="https://mthelm85.github.io/PlutoMCP.jl",
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/mthelm85/PlutoMCP.jl",
    devbranch="master",
)
