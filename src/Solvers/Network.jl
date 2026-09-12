struct Port
    positive::Union{Symbol,String}
    negative::Union{Symbol,String}
    reference_impedance::Float64
    name::Union{Nothing,Symbol}
    function Port(positive,negative;reference_impedance=50.,name=nothing)
        z0=Float64(reference_impedance)
        isfinite(z0)&&z0>0||throw(ArgumentError("port reference impedance must be finite and positive"))
        new(positive,negative,z0,name===nothing ? nothing : Symbol(name))
    end
end

struct NetworkResult
    compiled::AbstractCompiledCircuit
    frequencies::Vector{Float64}
    ports::Vector{Port}
    z::Array{ComplexF64,3}
    stats::Dict{Symbol,Any}
end

frequencies(result::NetworkResult)=result.frequencies

function _port_node_index(cc,node)
    index=_hierarchical_net_index(cc,node)
    index===nothing&&throw(KeyError(node))
    Int(index)
end

function _port_selector(cc,port::Port)
    positive=_port_node_index(cc,port.positive); negative=_port_node_index(cc,port.negative)
    positive==negative&&throw(ArgumentError("port terminals must be distinct"))
    selector=zeros(ComplexF64,cc.n)
    positive>0&&(selector[positive]+=1)
    negative>0&&(selector[negative]-=1)
    selector
end

function port_response(c,frequency_specification::Union{Pair,AbstractVector};ports,points=100,scale=:log,temperature=300.,kw...)
    port_list=ports isa Port ? Port[ports] : Port[ports...]
    isempty(port_list)&&throw(ArgumentError("at least one port is required"))
    fs=_small_signal_frequencies(frequency_specification;points=frequency_specification isa AbstractVector ? length(frequency_specification) : points,scale)
    cc=compile(c); operating_point_result=_require_converged(operating_point(cc;temperature,kw...),"network operating point"); op=operating_point_result.values[:,1]
    G,E=_static_dynamic_jacobians(cc,op;mode=:dc,temperature)
    selectors=hcat((_port_selector(cc,port) for port in port_list)...)
    count=length(port_list); z=zeros(ComplexF64,count,count,length(fs))
    for (frequency_index,frequency) in enumerate(fs)
        system=G+im*2π*frequency*E
        states=_solve_linear(system,selectors,"network matrix is singular at $(frequency) Hz")
        z[:,:,frequency_index]=selectors'*states
    end
    stats=_finalize_stats!(Dict{Symbol,Any}(:converged=>true,:temperature=>Float64(temperature),:points=>length(fs),:warnings=>String[]))
    NetworkResult(_snapshot_compiled(cc),Float64.(fs),deepcopy(port_list),z,stats)
end

impedance(result::NetworkResult)=copy(result.z)
function admittance(result::NetworkResult)
    output=similar(result.z)
    for index in eachindex(result.frequencies)
        output[:,:,index]=_solve_linear(result.z[:,:,index],Matrix{ComplexF64}(I,length(result.ports),length(result.ports)),"network impedance matrix is singular at $(result.frequencies[index]) Hz")
    end
    output
end

function _z0_matrix(ports)
    Matrix(Diagonal(ComplexF64[port.reference_impedance for port in ports]))
end

function network_parameters(result::NetworkResult,kind::Symbol=:z)
    kind===:z&&return impedance(result)
    kind===:y&&return admittance(result)
    count=length(result.ports); output=similar(result.z)
    if kind===:s
        z0=_z0_matrix(result.ports); root=Matrix(Diagonal(sqrt.(diag(z0)))); inverse_root=inv(root)
        for index in eachindex(result.frequencies)
            normalized=inverse_root*result.z[:,:,index]*inverse_root
            output[:,:,index]=(normalized-I)/(normalized+I)
        end
        return output
    end
    count==2||throw(ArgumentError("$(kind) parameters require exactly two ports"))
    for index in eachindex(result.frequencies)
        z=result.z[:,:,index]; determinant=det(z)
        if kind===:abcd
            iszero(z[2,1])&&throw(LinearSolveError("ABCD conversion is singular at $(result.frequencies[index]) Hz"))
            output[:,:,index]=[z[1,1]/z[2,1] determinant/z[2,1]; inv(z[2,1]) z[2,2]/z[2,1]]
        elseif kind===:h
            iszero(z[2,2])&&throw(LinearSolveError("hybrid conversion is singular at $(result.frequencies[index]) Hz"))
            output[:,:,index]=[determinant/z[2,2] z[1,2]/z[2,2]; -z[2,1]/z[2,2] inv(z[2,2])]
        else
            throw(ArgumentError("network parameter kind must be :z, :y, :s, :abcd, or :h"))
        end
    end
    output
end

function renormalize(result::NetworkResult,reference_impedances)
    values=reference_impedances isa Real ? fill(Float64(reference_impedances),length(result.ports)) : Float64.(reference_impedances)
    length(values)==length(result.ports)||throw(DimensionMismatch("one reference impedance is required per port"))
    all(value->isfinite(value)&&value>0,values)||throw(ArgumentError("reference impedances must be finite and positive"))
    ports=[Port(port.positive,port.negative;reference_impedance=values[index],name=port.name) for (index,port) in enumerate(result.ports)]
    NetworkResult(result.compiled,copy(result.frequencies),ports,copy(result.z),copy(result.stats))
end

provenance(result::NetworkResult)=Dict(:amber_version=>v"0.1.0",:topology_fingerprint=>result.compiled.fingerprint,
    :analysis=>"Network",:statistics=>copy(result.stats),:unit_system=>:SI,:warnings=>copy(get(result.stats,:warnings,String[])))
report(result::NetworkResult)=Dict(:analysis=>"Network",:ports=>length(result.ports),:statistics=>copy(result.stats))
