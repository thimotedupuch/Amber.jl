struct SimulationResult{T,A<:AbstractAnalysis}
    compiled::AbstractCompiledCircuit
    analysis::A
    axis::Vector{Float64}
    values::Matrix{T}
    stats::Dict{Symbol,Any}
    function SimulationResult(compiled::AbstractCompiledCircuit, analysis::A, axis::Vector{Float64}, values::Matrix{T}, stats::Dict{Symbol,Any}) where {T,A<:AbstractAnalysis}
        new{T,A}(_snapshot_compiled(compiled), analysis, axis, values, stats)
    end
end

frequencies(r::SimulationResult{<:Any,<:SmallSignal})=r.axis

_unknown_trace(r,index::Integer)=index==0 ? zeros(eltype(r.values),length(r.axis)) : vec(r.values[Int(index),:])

function _hierarchical_net_index(cc,name)
    target=String(name); design=cc.design; hierarchy=cc.hierarchical_topology.hierarchy
    for (local_index,segment) in enumerate(design.root_ir.net_names)
        rendered=_render_segment((_name(design.names,segment.base),segment.index))
        rendered==target&&return hierarchy.root_net_to_solver[local_index]
    end
    split_at=findlast(==('.'),target); split_at===nothing&&return nothing
    instance_path=target[1:split_at-1]; local_name=target[split_at+1:end]
    for (instance,record) in enumerate(design.root.records)
        string(InstancePath(_path_segments(design,record.path)))==instance_path||continue
        template=design.templates.templates[Int(record.template)]
        for (port_index,port) in enumerate(template.ports)
            _name(template.names,port.name)==local_name||continue
            actual_index=Int(record.connections.start)+port_index-1
            root_net=design.root.connection_data[actual_index]
            return hierarchy.root_net_to_solver[Int(root_net)]
        end
        for local_index in (length(template.ports)+1):length(template.body.net_names)
            segment=template.body.net_names[local_index]
            _render_segment((_name(template.names,segment.base),segment.index))==local_name||continue
            return hierarchy.instance_internal_base[instance]+local_index-length(template.ports)-1
        end
    end
    nothing
end

_batch_terminal(batch::ResistorBatch,index,device)=index==1 ? batch.p[device] : batch.n[device]
_batch_terminal(batch::PrimitiveBatch,index,device)=batch.terminals[index][device]

function _hierarchical_device(cc,name)
    target=String(name)
    for batch in cc.parameters.batches, device in eachindex(batch.locators)
        instance_name,device_name=_locator_device_name(cc.design,batch.locators[device])
        path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
        path==target&&return batch,device
    end
    nothing
end

function _findnode(cc,name)
    s=Symbol(name); findfirst(n->n.name===s,cc.circuit.nodes)
end
function voltage(r::SimulationResult,name::Union{Symbol,String})
    if r.compiled.design !== nothing
        index=_hierarchical_net_index(r.compiled,name)
        index===nothing&&throw(KeyError(name))
        return _unknown_trace(r,index)
    end
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
    if r.compiled.design !== nothing
        located=_hierarchical_device(r.compiled,name); located===nothing&&throw(KeyError(name))
        batch,device=located
        kind=_batch_kind(batch)
        parameters=batch.parameters[device]
        if batch isa PrimitiveBatch && batch.branch_unknowns[device]!=0
            return _unknown_trace(r,batch.branch_unknowns[device])
        end
        terminal(index)=_unknown_trace(r,_batch_terminal(batch,index,device))
        va=terminal(1); vb=terminal(2)
        kind===:resistor&&return (va-vb).*batch.conductance[device]
        kind===:conductance&&return (va-vb).*parameters.value
        kind===:capacitor&&return parameters.value.*_derivative(r,va-vb).+
            (hasproperty(parameters,:leakage_resistance) ? (va-vb)./parameters.leakage_resistance : zero(va))
        if kind===:current_source
            r.analysis isa SmallSignal&&return fill(ComplexF64(get(parameters,:ac,0.)),length(r.axis))
            r.analysis isa OperatingPoint&&return [Float64(get(parameters,:dc,0.))]
            waveform=get(parameters,:waveform,nothing)
            return waveform===nothing ? fill(Float64(get(parameters,:dc,0.)),length(r.axis)) : waveform.(r.axis)
        elseif kind===:diode
            model=parameters.model; voltage_values=va-vb; temperature=get(r.stats,:temperature,300.)
            conductive=map(value->_diode_conduction(model,real(value),temperature)[1],voltage_values)
            capacitance=map(value->differential_capacitance(model,real(value);temperature),voltage_values)
            return conductive.+capacitance.*_derivative(r,voltage_values)
        elseif kind===:npn
            vc=terminal(1); vbias=terminal(2); ve=terminal(3); model=parameters.model
            vt=_thermal_voltage(get(r.stats,:temperature,300.)); If=model.saturation_current.*expm1.(clamp.((vbias.-ve)./vt,-80,40)); Ir=model.saturation_current.*expm1.(clamp.((vbias.-vc)./vt,-80,40))
            αf=model.forward_beta/(model.forward_beta+1); αr=model.reverse_beta/(model.reverse_beta+1)
            collector=αf.*If.*(1 .+(vc.-ve)./model.early_voltage).-Ir; base=(1-αf).*If.+(1-αr).*Ir
            branch===:base&&return base
            branch===:emitter&&return .-collector.-base
            return collector
        elseif kind in (:nmos,:pmos)
            vd=terminal(1); vg=terminal(2); vs=terminal(3); bulk=terminal(4); model=parameters.model
            channel=map((d,g,s,b)->_mosfet_channel(model,kind,real(d),real(g),real(s),real(b))[1],vd,vg,vs,bulk)
            igs=model.gate_source_capacitance.*_derivative(r,vg.-vs)
            igd=model.gate_drain_capacitance.*_derivative(r,vg.-vd)
            igb=model.gate_bulk_capacitance.*_derivative(r,vg.-bulk)
            branch===:gate&&return igs.+igd.+igb
            branch===:source&&return .-channel.-igs
            branch===:bulk&&return .-igb
            return channel.-igd
        elseif kind===:switch
            control=terminal(3)-terminal(4)
            return (va-vb).*_switch_conductance.(Ref(parameters.model),real.(control))
        elseif kind===:vccs
            return parameters.gm.*(terminal(1)-terminal(2))
        elseif kind===:cccs
            return parameters.gain.*_unknown_trace(r,batch.control_unknowns[device])
        end
        throw(ArgumentError("current is not implemented for hierarchical device $(name) of kind $(kind)"))
    end
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
        v=va-vb; return x.parameters[:value].*_derivative(r,v).+
            v./get(x.parameters,:external_leakage_resistance,
                get(x.parameters,:leakage_resistance,Inf))
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
    elseif x.kind in (:nmos,:pmos)
        drain,gate,source,bulk=x.terminals
        vd=voltage(r,drain.name); vg=voltage(r,gate.name)
        vs=voltage(r,source.name); vb=voltage(r,bulk.name); model=x.parameters[:model]
        channel=map((d,g,s,b)->_mosfet_channel(model,x.kind,real(d),real(g),real(s),real(b))[1],vd,vg,vs,vb)
        igs=model.gate_source_capacitance.*_derivative(r,vg.-vs)
        igd=model.gate_drain_capacitance.*_derivative(r,vg.-vd)
        igb=model.gate_bulk_capacitance.*_derivative(r,vg.-vb)
        branch===:gate&&return igs.+igd.+igb
        branch===:source&&return .-channel.-igs
        branch===:bulk&&return .-igb
        return channel.-igd
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
    output=similar(values)
    if length(values)==2
        output.=((values[2]-values[1])/(r.axis[2]-r.axis[1])); return output
    end
    h0=r.axis[2]-r.axis[1]; h1=r.axis[3]-r.axis[2]
    output[1]=-(2h0+h1)/(h0*(h0+h1))*values[1]+(h0+h1)/(h0*h1)*values[2]-h0/(h1*(h0+h1))*values[3]
    for i in 2:length(values)-1
        left=r.axis[i]-r.axis[i-1]; right=r.axis[i+1]-r.axis[i]
        output[i]=-right/(left*(left+right))*values[i-1]+(right-left)/(left*right)*values[i]+left/(right*(left+right))*values[i+1]
    end
    h0=r.axis[end-1]-r.axis[end-2]; h1=r.axis[end]-r.axis[end-1]
    output[end]=h1/(h0*(h0+h1))*values[end-2]-(h0+h1)/(h0*h1)*values[end-1]+(h0+2h1)/(h1*(h0+h1))*values[end]
    output
end

function power(r::SimulationResult,name::Union{Symbol,String})
    if r.compiled.design !== nothing
        located=_hierarchical_device(r.compiled,name); located===nothing&&throw(KeyError(name))
        batch,device=located; kind=_batch_kind(batch)
        terminal(index)=_unknown_trace(r,_batch_terminal(batch,index,device))
        if kind===:npn
            return (terminal(1)-terminal(3)).*current(r,name,:collector).+
                (terminal(2)-terminal(3)).*current(r,name,:base)
        elseif kind in (:nmos,:pmos)
            return (terminal(1)-terminal(3)).*current(r,name,:drain).+
                (terminal(2)-terminal(3)).*current(r,name,:gate).+
                (terminal(4)-terminal(3)).*current(r,name,:bulk)
        end
        return (terminal(1)-terminal(2)).*current(r,name)
    end
    ci=_findcomponent(r.compiled,name); ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    if x.kind===:npn
        collector,base,emitter=get(x.parameters,:external_terminals,(x.terminals[1],x.terminals[2],x.terminals[3]))
        return voltage(r,collector.name,emitter.name).*current(r,name,:collector).+voltage(r,base.name,emitter.name).*current(r,name,:base)
    elseif x.kind in (:nmos,:pmos)
        drain,gate,source,bulk=x.terminals
        return voltage(r,drain.name,source.name).*current(r,name,:drain).+
            voltage(r,gate.name,source.name).*current(r,name,:gate).+
            voltage(r,bulk.name,source.name).*current(r,name,:bulk)
    end
    terminals=get(x.parameters,:external_terminals,(x.terminals[1],x.terminals[2]))
    voltage(r,terminals[1].name,terminals[2].name).*current(r,name)
end

function charge(r::SimulationResult,name::Union{Symbol,String})
    if r.compiled.design !== nothing
        located=_hierarchical_device(r.compiled,name); located===nothing&&throw(KeyError(name))
        batch,device=located; kind=_batch_kind(batch)
        voltage_values=_unknown_trace(r,_batch_terminal(batch,1,device))-_unknown_trace(r,_batch_terminal(batch,2,device))
        kind===:capacitor&&return batch.parameters[device].value.*voltage_values
        kind===:diode&&return map(value->charge(batch.parameters[device].model,real(value);
            temperature=get(r.stats,:temperature,300.)),voltage_values)
        throw(ArgumentError("charge is not available for hierarchical device $(name)"))
    end
    ci=_findcomponent(r.compiled,name); ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    v=voltage(r,x.terminals[1].name,x.terminals[2].name)
    x.kind===:capacitor&&return x.parameters[:value].*v
    x.kind===:diode&&return map(value->charge(x.parameters[:model],real(value);temperature=get(r.stats,:temperature,300.)),v)
    throw(ArgumentError("charge is not available for component $(name)"))
end

function state(r::SimulationResult,name::Union{Symbol,String},state_name::Symbol)
    if r.compiled.design !== nothing
        located=_hierarchical_device(r.compiled,name); located===nothing&&throw(KeyError(name))
        batch,device=located; batch isa PrimitiveBatch||throw(KeyError((name,state_name)))
        contract=device_contract(_batch_kind(batch)); state_index=findfirst(==(state_name),contract.states)
        state_index===nothing&&throw(KeyError((name,state_name)))
        return _unknown_trace(r,batch.state_unknowns[device][state_index])
    end
    component=_findcomponent(r.compiled,name); component===nothing&&throw(KeyError(name))
    index=get(r.compiled.states,(component,state_name),nothing)
    index===nothing&&throw(KeyError((name,state_name)))
    vec(r.values[index,:])
end
trace(r,x)=x isa Observable ? _observable(r,x) : voltage(r,x)
_observable(r,o::Observable)=o.kind===:voltage ? (o.extra===nothing ? voltage(r,o.target isa AbstractNode ? o.target.name : o.target) : voltage(r,o.target.name,o.extra.name)) : current(r,o.target,o.extra)
transfer(r::SimulationResult;input,output)=_observable(r,output)./_observable(r,input)
magnitude(x)=abs.(x)
function _unwrap_phase(values)
    isempty(values)&&return Float64[]
    raw=Float64.(values); output=copy(raw); offset=0.
    for index in 2:length(output)
        jump=raw[index]-raw[index-1]
        if jump>π
            offset-=2π
        elseif jump < -π
            offset+=2π
        end
        output[index]=raw[index]+offset
    end
    output
end
function phase(x;unwrap=false,degrees=false)
    values=angle.(x)
    unwrap&&(values=_unwrap_phase(values))
    degrees ? rad2deg.(values) : values
end

@enum DeviceRegion Cutoff ForwardActive Saturation Triode
function region(r::SimulationResult,name::Union{Symbol,String})
    if r.compiled.design !== nothing
        located=_hierarchical_device(r.compiled,name); located===nothing&&throw(KeyError(name))
        batch,device=located; kind=_batch_kind(batch)
        terminal(index)=_unknown_trace(r,_batch_terminal(batch,index,device))[1]
        if kind===:npn
            vc,vb,ve=terminal(1),terminal(2),terminal(3)
            return vb-ve<.45 ? Cutoff : vb>vc ? Saturation : ForwardActive
        elseif kind in (:nmos,:pmos)
            polarity=kind===:nmos ? 1. : -1.; vd,vg,vs,vb=polarity.*(terminal(1),terminal(2),terminal(3),terminal(4))
            if vd<vs; vd,vs=vs,vd end
            model=batch.parameters[device].model
            threshold=model.threshold_voltage+model.body_effect*(sqrt(max(2model.surface_potential+vs-vb,eps()))-sqrt(2model.surface_potential))
            overdrive=vg-vs-threshold
            return overdrive<=0 ? Cutoff : vd-vs<overdrive ? Triode : Saturation
        end
        throw(ArgumentError("region is only defined for BJT and MOSFET devices"))
    end
    ci=_findcomponent(r.compiled,name)
    ci===nothing&&throw(KeyError(name)); x=r.compiled.circuit.components[ci]
    if x.kind===:npn
        c,b,e=x.terminals; vb=voltage(r,b.name)[1]; ve=voltage(r,e.name)[1]; vc=voltage(r,c.name)[1]
        return vb-ve<.45 ? Cutoff : vb>vc ? Saturation : ForwardActive
    elseif x.kind in (:nmos,:pmos)
        d,g,s,b=x.terminals; polarity=x.kind===:nmos ? 1. : -1.
        vd,vg,vs,vb=polarity.*(voltage(r,d.name)[1],voltage(r,g.name)[1],voltage(r,s.name)[1],voltage(r,b.name)[1])
        if vd<vs; vd,vs=vs,vd end
        threshold=x.parameters[:model].threshold_voltage+x.parameters[:model].body_effect*(sqrt(max(2x.parameters[:model].surface_potential+vs-vb,eps()))-sqrt(2x.parameters[:model].surface_potential))
        overdrive=vg-vs-threshold
        return overdrive<=0 ? Cutoff : vd-vs<overdrive ? Triode : Saturation
    end
    throw(ArgumentError("region is only defined for BJT and MOSFET devices"))
end

_snapshot_value(value)=value
_snapshot_value(value::AbstractWaveform)=string(typeof(value),NamedTuple{fieldnames(typeof(value))}(Tuple(getfield(value,key) for key in fieldnames(typeof(value)))))
_snapshot_value(value::NamedTuple)=Dict(key=>_snapshot_value(item) for (key,item) in pairs(value))
function _snapshot_value(value::Union{ThinFilm,SMD0603,C0G,DebyeBranches,JunctionDiode,GummelPoonBJT,Level1MOSFET,BehavioralOpAmp,VoltageControlledSwitch,SmoothSwitch,EventSwitch})
    Dict(:model=>string(typeof(value)),:parameters=>_snapshot_value(getfield(value,:data)))
end
function provenance(r)
    parameters=Dict{String,Any}()
    for batch in r.compiled.parameters.batches, device in eachindex(batch.locators)
        instance_name,device_name=_locator_device_name(r.compiled.design,batch.locators[device])
        path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
        parameters[path]=_snapshot_value(batch.parameters[device])
    end
    Dict(:amber_version=>v"0.1.0",:design_fingerprint=>r.compiled.design.structural_fingerprint,
        :parameter_fingerprint=>r.compiled.parameters.fingerprint,:topology_fingerprint=>r.compiled.fingerprint,
        :analysis=>string(typeof(r.analysis)),:parameters=>parameters,:unit_system=>:SI,
        :statistics=>copy(r.stats),:warnings=>copy(get(r.stats,:warnings,String[])))
end

function report(r::SimulationResult)
    devices=Dict{String,Any}()
    if r.analysis isa OperatingPoint
        for batch in r.compiled.parameters.batches
            _batch_kind(batch)===:npn||continue
            for device in eachindex(batch.locators)
                instance_name,device_name=_locator_device_name(r.compiled.design,batch.locators[device])
                path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
                collector=_unknown_trace(r,_batch_terminal(batch,1,device)); base=_unknown_trace(r,_batch_terminal(batch,2,device)); emitter=_unknown_trace(r,_batch_terminal(batch,3,device))
                devices[path]=(vbe=(base-emitter)[1],vce=(collector-emitter)[1],
                    collector_current=current(r,path,:collector)[1],base_current=current(r,path,:base)[1])
            end
        end
    end
    Dict(:analysis=>string(typeof(r.analysis)),:statistics=>copy(r.stats),:devices=>devices)
end

function validity_report(r::SimulationResult)
    devices=Dict{String,Any}(); warnings=copy(get(r.stats,:warnings,String[]))
    for batch in r.compiled.parameters.batches, device in eachindex(batch.locators)
        kind=_batch_kind(batch)
        instance_name,device_name=_locator_device_name(r.compiled.design,batch.locators[device])
        path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
        if kind===:diode
            terminal_voltage=real.(_unknown_trace(r,_batch_terminal(batch,1,device))-_unknown_trace(r,_batch_terminal(batch,2,device)))
            device_current=real.(current(r,path))
            devices[path]=(maximum_forward_current=maximum(device_current),maximum_reverse_voltage=max(0.,-minimum(terminal_voltage)),model_validity=:satisfied)
        elseif kind===:capacitor
            ripple=current(r,path); rms=sqrt(sum(abs2,ripple)/length(ripple))
            devices[path]=(ripple_current_rms=rms,rated_ripple_current=:unspecified)
            push!(warnings,"$(path): rated ripple current is unspecified; thermal validity cannot be evaluated")
        elseif r.analysis isa TransientNoise&&kind in (:nmos,:pmos)
            push!(warnings,"$(path): Level1MOSFET noise excludes body-diode, junction, substrate, and foundry BSIM mechanisms")
        end
    end
    Dict(:devices=>devices,:warnings=>warnings)
end
function available_observables(x)
    contract=device_contract(x.kind); contract===nothing&&throw(ArgumentError("unsupported device kind $(x.kind)"))
    contract.observables
end
