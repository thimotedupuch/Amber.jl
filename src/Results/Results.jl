struct SimulationResult{T,A<:AbstractAnalysis}
    compiled::CompiledCircuit
    analysis::A
    axis::Vector{Float64}
    values::Matrix{T}
    stats::Dict{Symbol,Any}
    function SimulationResult(compiled::CompiledCircuit, analysis::A, axis::Vector{Float64}, values::Matrix{T}, stats::Dict{Symbol,Any}) where {T,A<:AbstractAnalysis}
        new{T,A}(_snapshot_compiled(compiled), analysis, axis, values, stats)
    end
end

frequencies(r::SimulationResult{<:Any,<:SmallSignal})=r.axis
function _findnode(cc,name)
    s=Symbol(name); findfirst(n->n.name===s,cc.circuit.nodes)
end
function voltage(r::SimulationResult,name::Union{Symbol,String})
    i=_findnode(r.compiled,name)
    if i===nothing
        named=get(r.compiled.circuit.metadata,:named_observations,Dict{Symbol,Any}())
        observable=get(named,Symbol(name),nothing)
        observable===nothing&&throw(KeyError(name))
        observable isa Observable&&observable.kind===:voltage||throw(ArgumentError("named observation $(name) is not a voltage"))
        return _observable(r,observable)
    end
    n=r.compiled.circuit.nodes[i]
    n.id==0 ? zeros(eltype(r.values),length(r.axis)) : vec(r.values[r.compiled.node_index[n.id],:])
end
voltage(r::SimulationResult,a::Union{Symbol,String},b::Union{Symbol,String})=voltage(r,a)-voltage(r,b)
function current(r::SimulationResult,name::Union{Symbol,String},branch=nothing)
    ci=_findcomponent(r.compiled,name)
    if ci===nothing&&branch===nothing&&occursin('.',String(name))
        parts=split(String(name),'.'); inferred=Symbol(parts[end]); prefix=Symbol(join(parts[1:end-1],'.'))
        ci=_findcomponent(r.compiled,prefix); ci!==nothing&&(branch=inferred)
    end
    ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    haskey(r.compiled.branches,ci)&&return vec(r.values[r.compiled.branches[ci],:])
    a,b=x.terminals[1:2]; va=voltage(r,a.name); vb=voltage(r,b.name)
    x.kind===:resistor&&return (va-vb)/x.parameters[:value]
    x.kind===:conductance&&return (va-vb)*x.parameters[:value]
    if x.kind===:capacitor
        v=va-vb; return x.parameters[:value].*_derivative(r,v).+v./get(x.parameters,:leakage_resistance,Inf)
    elseif x.kind===:current_source
        if r.analysis isa SmallSignal
            return fill(ComplexF64(get(x.parameters,:ac,0.)),length(r.axis))
        elseif r.analysis isa OperatingPoint
            return [Float64(get(x.parameters,:dc,0.))]
        end
        waveform=get(x.parameters,:waveform,nothing)
        return waveform===nothing ? fill(Float64(get(x.parameters,:dc,0.)),length(r.axis)) : waveform.(r.axis)
    elseif x.kind===:diode
        model=x.parameters[:model]; v=va-vb; temperature=get(r.stats,:temperature,300.)
        conductive=map(value->_diode_conduction(model,real(value),temperature)[1],v)
        capacitance=map(value->differential_capacitance(model,real(value);temperature),v)
        return conductive.+capacitance.*_derivative(r,v)
    elseif x.kind===:npn
        collector,base,emitter=x.terminals
        vc=voltage(r,collector.name); vb=voltage(r,base.name); ve=voltage(r,emitter.name); model=x.parameters[:model]
        vt=_thermal_voltage(get(r.stats,:temperature,300.)); If=model.saturation_current.*expm1.(clamp.((vb.-ve)./vt,-80,40)); Ir=model.saturation_current.*expm1.(clamp.((vb.-vc)./vt,-80,40))
        αf=model.forward_beta/(model.forward_beta+1); αr=model.reverse_beta/(model.reverse_beta+1)
        ic=αf.*If.*(1 .+(vc.-ve)./model.early_voltage).-Ir; ib=(1-αf).*If.+(1-αr).*Ir
        branch===:base&&return ib
        branch===:emitter&&return .-ic.-ib
        return ic
    elseif x.kind===:switch
        control=voltage(r,x.terminals[3].name)-voltage(r,x.terminals[4].name); model=x.parameters[:model]
        conductance=_switch_conductance.(Ref(model),real.(control))
        return (va-vb).*conductance
    elseif x.kind===:vccs
        control_positive,control_negative=x.terminals[1:2]
        return x.parameters[:gm].*voltage(r,control_positive.name,control_negative.name)
    elseif x.kind===:cccs
        control_name=x.parameters[:control]
        control_index=_findcomponent(r.compiled,control_name)
        control_index===nothing&&throw(ArgumentError("$(x.name) refers to unknown controlling component $(control_name)"))
        control_branch=get(r.compiled.branches,control_index,nothing)
        control_branch===nothing&&throw(ArgumentError("$(x.name) requires branch current from $(control_name), but that current is unavailable"))
        return x.parameters[:gain].*vec(r.values[control_branch,:])
    end
    throw(ArgumentError("current is not implemented for component $(x.name) of kind $(x.kind)"))
end

function _findcomponent(cc,name)
    s=Symbol(name); findfirst(x->x.name===s,cc.circuit.components)
end

function _derivative(r::SimulationResult,values)
    if r.analysis isa SmallSignal
        return im.*2π.*r.axis.*values
    elseif length(r.axis)==1
        return zero(values)
    end
    output=similar(values); output[1]=(values[2]-values[1])/(r.axis[2]-r.axis[1])
    for i in 2:length(values); output[i]=(values[i]-values[i-1])/(r.axis[i]-r.axis[i-1]) end
    output
end

function power(r::SimulationResult,name::Union{Symbol,String})
    ci=_findcomponent(r.compiled,name); ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    if x.kind===:npn
        collector,base,emitter=get(x.parameters,:external_terminals,(x.terminals[1],x.terminals[2],x.terminals[3]))
        return voltage(r,collector.name,emitter.name).*current(r,name,:collector).+voltage(r,base.name,emitter.name).*current(r,name,:base)
    end
    terminals=get(x.parameters,:external_terminals,(x.terminals[1],x.terminals[2]))
    voltage(r,terminals[1].name,terminals[2].name).*current(r,name)
end

function charge(r::SimulationResult,name::Union{Symbol,String})
    ci=_findcomponent(r.compiled,name); ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    v=voltage(r,x.terminals[1].name,x.terminals[2].name)
    x.kind===:capacitor&&return x.parameters[:value].*v
    x.kind===:diode&&return map(value->charge(x.parameters[:model],real(value);temperature=get(r.stats,:temperature,300.)),v)
    throw(ArgumentError("charge is not available for component $(name)"))
end

function state(r::SimulationResult,name::Union{Symbol,String},state_name::Symbol)
    component=_findcomponent(r.compiled,name); component===nothing&&throw(KeyError(name))
    index=get(r.compiled.states,(component,state_name),nothing)
    index===nothing&&throw(KeyError((name,state_name)))
    vec(r.values[index,:])
end
trace(r,x)=x isa Observable ? _observable(r,x) : voltage(r,x)
_observable(r,o::Observable)=o.kind===:voltage ? (o.extra===nothing ? voltage(r,o.target isa AbstractNode ? o.target.name : o.target) : voltage(r,o.target.name,o.extra.name)) : current(r,o.target isa Component ? o.target.name : o.target,o.extra)
transfer(r::SimulationResult;input,output)=_observable(r,output)./_observable(r,input)
magnitude(x)=abs.(x)
phase(x)=angle.(x)

@enum BJTRegion Cutoff ForwardActive Saturation
function region(r::SimulationResult,name::Union{Symbol,String})
    ci=_findcomponent(r.compiled,name)
    ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    x.kind===:npn||throw(ArgumentError("region is only defined for BJT devices"))
    c,b,e=x.terminals; vb=voltage(r,b.name)[1]; ve=voltage(r,e.name)[1]; vc=voltage(r,c.name)[1]
    vb-ve<.45 ? Cutoff : vb>vc ? Saturation : ForwardActive
end

_snapshot_value(value)=value
_snapshot_value(value::AbstractWaveform)=string(typeof(value),NamedTuple{fieldnames(typeof(value))}(Tuple(getfield(value,key) for key in fieldnames(typeof(value)))))
_snapshot_value(value::NamedTuple)=Dict(key=>_snapshot_value(item) for (key,item) in pairs(value))
function _snapshot_value(value::Union{ThinFilm,SMD0603,C0G,DebyeBranches,JunctionDiode,GummelPoonBJT,BehavioralOpAmp,VoltageControlledSwitch,SmoothSwitch,EventSwitch})
    Dict(:model=>string(typeof(value)),:parameters=>_snapshot_value(getfield(value,:data)))
end
function provenance(r)
    parameters=Dict(component.name=>Dict(key=>_snapshot_value(value) for (key,value) in component.parameters if key!==:external_terminals) for component in r.compiled.circuit.components)
    Dict(:amber_version=>v"0.1.0",:topology_fingerprint=>r.compiled.fingerprint,:analysis=>string(typeof(r.analysis)),
        :parameters=>parameters,:unit_system=>:SI,:statistics=>copy(r.stats),:warnings=>copy(get(r.stats,:warnings,String[])))
end

function report(r::SimulationResult)
    devices=Dict{Symbol,Any}()
    if r.analysis isa OperatingPoint
        for component in r.compiled.circuit.components
            component.kind===:npn||continue
            c,b,e=component.terminals; devices[component.name]=(
                vbe=voltage(r,b.name,e.name)[1],vce=voltage(r,c.name,e.name)[1],
                collector_current=current(r,component.name,:collector)[1],base_current=current(r,component.name,:base)[1],
                region=region(r,component.name))
        end
    end
    Dict(:analysis=>string(typeof(r.analysis)),:statistics=>copy(r.stats),:devices=>devices)
end

function validity_report(r::SimulationResult)
    devices=Dict{Symbol,Any}(); warnings=String[]
    for component in r.compiled.circuit.components
        if component.kind===:diode
            terminal_voltage=real.(voltage(r,component.terminals[1].name,component.terminals[2].name)); device_current=real.(current(r,component.name))
            devices[component.name]=(maximum_forward_current=maximum(device_current),maximum_reverse_voltage=max(0.,-minimum(terminal_voltage)),model_validity=:satisfied)
        elseif component.kind===:capacitor&&!occursin('.',String(component.name))
            ripple=current(r,component.name); rms=sqrt(sum(abs2,ripple)/length(ripple))
            devices[component.name]=(ripple_current_rms=rms,rated_ripple_current=:unspecified)
            push!(warnings,"$(component.name): rated ripple current is unspecified; thermal validity cannot be evaluated")
        end
    end
    Dict(:devices=>devices,:warnings=>warnings)
end
function available_observables(x::Component)
    contract=device_contract(x.kind); contract===nothing&&throw(ArgumentError("unsupported device kind $(x.kind)"))
    contract.observables
end
