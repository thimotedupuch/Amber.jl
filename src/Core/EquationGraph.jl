"""Numerically elaborated unknown ordering for the generalized MNA system."""
struct EquationGraph
    node_index::Dict{Int,Int}
    branches::Dict{Int,Int}
    states::Dict{Tuple{Int,Symbol},Int}
    unknown_count::Int
end

function equation_graph(c::Circuit)
    ids=sort(unique(n.id for n in c.nodes if n.id!=0))
    nodes=Dict(id=>i for (i,id) in enumerate(ids)); branches=Dict{Int,Int}(); states=Dict{Tuple{Int,Symbol},Int}(); k=length(ids)
    for (i,x) in enumerate(c.components)
        if x.kind in (:voltage_source,:inductor,:opamp,:vcvs,:ccvs); k+=1; branches[i]=k end
        if x.kind===:opamp; k+=1; states[(i,:dominant_pole)]=k end
    end
    EquationGraph(nodes,branches,states,k)
end
