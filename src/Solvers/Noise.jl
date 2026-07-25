struct NoiseResult
    compiled::CompiledCircuit
    frequencies::Vector{Float64}
    output_noise_density::Vector{Float64}
    input_referred_noise_density::Union{Nothing,Vector{Float64}}
    output::Observable
    stats::Dict{Symbol,Any}
    function NoiseResult(compiled::CompiledCircuit, frequencies::Vector{Float64}, output_noise_density::Vector{Float64}, input_referred_noise_density::Union{Nothing,Vector{Float64}}, output::Observable,stats::Dict{Symbol,Any})
        new(_snapshot_compiled(compiled), frequencies, output_noise_density, input_referred_noise_density, deepcopy(output),stats)
    end
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
        contract=device_contract(x.kind); (contract===nothing||!contract.noise)&&continue
        a,b=map(n->_idx(cc,n),x.terminals[1:2])
        if x.kind===:resistor
            push!(sources,(a,b,4*boltzmann*temperature/Float64(x.parameters[:value])))
        elseif x.kind===:diode
            model=x.parameters[:model]; voltage_drop=_v(op,a)-_v(op,b); diode_current,_=_diode_conduction(model,voltage_drop,temperature)
            push!(sources,(a,b,2*elementary_charge*abs(diode_current)))
        elseif x.kind===:npn
            model=x.parameters[:model]; c,base,e=map(n->_idx(cc,n),x.terminals)
            vc,vb,ve=_v(op,c),_v(op,base),_v(op,e)
            vt=_thermal_voltage(temperature); If=model.saturation_current*expm1(clamp((vb-ve)/vt,-80,40)); Ir=model.saturation_current*expm1(clamp((vb-vc)/vt,-80,40))
            αf=model.forward_beta/(model.forward_beta+1); collector_current=αf*If*(1+(vc-ve)/model.early_voltage)-Ir
            push!(sources,(c,e,2*elementary_charge*abs(collector_current)))
            push!(sources,(base,e,2*elementary_charge*abs(collector_current/model.forward_beta)))
        elseif x.kind in (:nmos,:pmos)
            model=x.parameters[:model]; d,g,s,b=map(n->_idx(cc,n),x.terminals)
            _,derivatives=_mosfet_channel(model,x.kind,_v(op,d),_v(op,g),_v(op,s),_v(op,b))
            gm=abs(derivatives[2])
            push!(sources,(d,s,4*boltzmann*temperature*model.noise_coefficient*gm))
        end
    end
    sources
end

function noise(c,range::Pair;output,referred_to=nothing,points=100,scale=:log,temperature=300.,kw...)
    _validate_frequency_range(range,points,scale); isfinite(temperature)&&temperature>0||throw(AnalysisValidationError("noise temperature must be finite and positive"))
    cc=compile(c); operating_point_result=_require_converged(operating_point(cc;temperature,kw...),"noise operating point"); op=operating_point_result.values[:,1]
    fs=scale===:log ? collect(10 .^ Base.range(log10(first(range)),log10(last(range)),length=points)) : collect(Base.range(first(range),last(range),length=points))
    _,Jz=residual_jacobian(cc,op,op,0.,0.;mode=:dc,temperature); _,combined=residual_jacobian(cc,op,op,0.,1.;mode=:dc,temperature); Jd=combined-Jz
    selector=_voltage_selector(cc,output); sources=_noise_sources(cc,op;temperature); density=zeros(Float64,length(fs)); gain=ones(Float64,length(fs))
    for (frequency_index,frequency) in enumerate(fs)
        system=Jz+im*2π*frequency*Jd; adjoint_solution=_solve_linear(system',selector,"noise adjoint matrix is singular at $(frequency) Hz"); spectral=0.
        for (a,b,source_density) in sources
            transfer=(a==0 ? 0 : conj(adjoint_solution[a]))-(b==0 ? 0 : conj(adjoint_solution[b]))
            spectral+=abs2(transfer)*source_density
        end
        density[frequency_index]=sqrt(max(spectral,0.))
        if referred_to!==nothing
            excitation=ac_excitation(cc;source=Symbol(referred_to)); response=_solve_linear(system,excitation,"noise gain matrix is singular at $(frequency) Hz")
            gain[frequency_index]=abs(dot(selector,response))
        end
    end
    warnings=String[]
    if referred_to!==nothing
        threshold=sqrt(eps(Float64))*max(maximum(gain),1.)
        any(<=(threshold),gain)&&push!(warnings,"input-referred noise is singular or unreliable near a transfer null")
    end
    referred=referred_to===nothing ? nothing : density./gain
    stats=_finalize_stats!(Dict{Symbol,Any}(:converged=>true,:temperature=>Float64(temperature),:points=>length(fs),:warnings=>warnings))
    NoiseResult(cc,Float64.(fs),density,referred,output,stats)
end

provenance(result::NoiseResult)=Dict(:amber_version=>v"0.1.0",:topology_fingerprint=>result.compiled.fingerprint,
    :analysis=>"Noise",:statistics=>copy(result.stats),:unit_system=>:SI,:warnings=>String[])
report(result::NoiseResult)=Dict(:analysis=>"Noise",:statistics=>copy(result.stats))
