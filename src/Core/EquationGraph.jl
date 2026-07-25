"""Numerically elaborated unknown ordering for the generalized MNA system."""
struct DeviceContract
    terminals::Int
    branch::Bool
    states::Vector{Symbol}
    dc_path::Bool
    noise::Bool
    observables::Tuple
end
_contract(terminals;branch=false,states=Symbol[],dc_path=false,noise=false,observables=(:voltage,:current,:power))=
    DeviceContract(terminals,branch,states,dc_path,noise,observables)
const _DEVICE_SPECS = Dict{Symbol,DeviceContract}(
    :resistor=>_contract(2;dc_path=true,noise=true), :conductance=>_contract(2;dc_path=true),
    :capacitor=>_contract(2;observables=(:voltage,:current,:power,:charge)), :current_source=>_contract(2),
    :voltage_source=>_contract(2;branch=true,dc_path=true), :inductor=>_contract(2;branch=true,dc_path=true),
    :vccs=>_contract(4), :vcvs=>_contract(4;branch=true,dc_path=true), :cccs=>_contract(2),
    :ccvs=>_contract(2;branch=true,dc_path=true), :diode=>_contract(2;dc_path=true,noise=true,observables=(:voltage,:current,:power,:charge)),
    :npn=>_contract(3;dc_path=true,noise=true),
    :nmos=>_contract(4;dc_path=true,noise=true), :pmos=>_contract(4;dc_path=true,noise=true),
    :switch=>_contract(4;dc_path=true),
    :opamp=>_contract(5;branch=true,states=[:dominant_pole],dc_path=true),
)
device_contract(kind::Symbol)=get(_DEVICE_SPECS,kind,nothing)

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
        spec=_DEVICE_SPECS[x.kind]
        if spec.branch; k+=1; branches[i]=k end
        for state in spec.states; k+=1; states[(i,state)]=k end
    end
    EquationGraph(nodes,branches,states,k)
end
