struct NoiseResult
    compiled::CompiledCircuit
    frequencies::Vector{Float64}
    output_noise_density::Vector{Float64}
    input_referred_noise_density::Union{Nothing,Vector{Float64}}
    output::Observable
end

output_noise_density(result::NoiseResult)=result.output_noise_density
input_referred_noise_density(result::NoiseResult)=result.input_referred_noise_density

function _voltage_selector(cc,observable::Observable)
    observable.kind===:voltage||throw(ArgumentError("noise output must be a voltage observable"))
    selector=zeros(ComplexF64,cc.n)
    target=observable.target isa AbstractNode ? observable.target.name : observable.target
    first_node=_findnode(cc,target); first_node===nothing&&throw(KeyError(target)); a=cc.circuit.nodes[first_node]
    a.id!=0&&(selector[cc.node_index[a.id]]+=1)
    if observable.extra!==nothing
        other=observable.extra isa AbstractNode ? observable.extra.name : observable.extra
        second_node=_findnode(cc,other); second_node===nothing&&throw(KeyError(other)); b=cc.circuit.nodes[second_node]
        b.id!=0&&(selector[cc.node_index[b.id]]-=1)
    end
    selector
end

function _noise_sources(cc,op;temperature=300.)
    boltzmann=1.380649e-23; elementary_charge=1.602176634e-19
    sources=Tuple{Int,Int,Float64}[]
    for (index,x) in enumerate(cc.circuit.components)
        a,b=map(n->_idx(cc,n),x.terminals[1:2])
        if x.kind===:resistor
            push!(sources,(a,b,4*boltzmann*temperature/Float64(x.parameters[:value])))
        elseif x.kind===:diode
            model=x.parameters[:model]; voltage_drop=_v(op,a)-_v(op,b); vt=.025852*model.ideality
            diode_current=model.saturation_current*expm1(clamp(voltage_drop/vt,-80,40))
            push!(sources,(a,b,2*elementary_charge*abs(diode_current)))
        elseif x.kind===:npn
            model=x.parameters[:model]; c,base,e=map(n->_idx(cc,n),x.terminals)
            vc,vb,ve=_v(op,c),_v(op,base),_v(op,e)
            collector_current=model.saturation_current*expm1(clamp((vb-ve)/.025852,-80,40))*(1+(vc-ve)/max(model.early_voltage,1e-9))
            push!(sources,(c,e,2*elementary_charge*abs(collector_current)))
            push!(sources,(base,e,2*elementary_charge*abs(collector_current/model.forward_beta)))
        end
    end
    sources
end

function noise(c,range::Pair;output,referred_to=nothing,points=100,scale=:log,temperature=300.,kw...)
    cc=compile(c); op=operating_point(cc).values[:,1]
    fs=scale===:log ? collect(10 .^ Base.range(log10(first(range)),log10(last(range)),length=points)) : collect(Base.range(first(range),last(range),length=points))
    _,Jz=residual_jacobian(cc,op,op,0.,0.;mode=:dc); _,combined=residual_jacobian(cc,op,op,0.,1.;mode=:dc); Jd=combined-Jz
    selector=_voltage_selector(cc,output); sources=_noise_sources(cc,op;temperature); density=zeros(Float64,length(fs)); gain=ones(Float64,length(fs))
    for (frequency_index,frequency) in enumerate(fs)
        system=Jz+im*2π*frequency*Jd; adjoint_solution=system'\selector; spectral=0.
        for (a,b,source_density) in sources
            transfer=(a==0 ? 0 : conj(adjoint_solution[a]))-(b==0 ? 0 : conj(adjoint_solution[b]))
            spectral+=abs2(transfer)*source_density
        end
        density[frequency_index]=sqrt(max(spectral,0.))
        if referred_to!==nothing
            excitation=ac_excitation(cc;source=Symbol(referred_to)); response=system\excitation
            gain[frequency_index]=abs(dot(selector,response))
        end
    end
    referred=referred_to===nothing ? nothing : density./gain
    NoiseResult(cc,Float64.(fs),density,referred,output)
end
