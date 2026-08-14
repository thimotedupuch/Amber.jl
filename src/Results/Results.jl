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

function _net_names(cc)
    sort!(unique!(reduce(vcat,values(_net_labels(cc.design,cc.topology));init=String[])))
end

function _device_names(cc)
    sort!([string(item.path) for item in devices(cc.design;limit=typemax(Int))])
end

_lookup_error(kind,name,candidates)=CircuitLookupError(kind,String(name),candidates)

function _observation_path(reference,body,names,prefix)
    if reference isa BuilderNet
        segment=body.net_names[Int(reference.id)]
        local_name=_render_segment((_name(names,segment.base),segment.index))
    elseif reference isa BuilderPrimitive
        local_name=_name(names,body.primitives[Int(reference.id)].name)
    elseif reference isa Union{Symbol,String}
        return String(reference)
    elseif reference===nothing
        return nothing
    else
        throw(ArgumentError("unsupported observation reference $(typeof(reference))"))
    end
    isempty(prefix) ? local_name : string(prefix,'.',local_name)
end

function _resolved_observation(value,body,names,prefix)
    value isa BuilderNet&&return voltage(Symbol(_observation_path(value,body,names,prefix)))
    value isa BuilderPrimitive&&return current(Symbol(_observation_path(value,body,names,prefix)))
    value isa Observable||throw(ArgumentError("unsupported observation value $(typeof(value))"))
    target=_observation_path(value.target,body,names,prefix)
    extra=_observation_path(value.extra,body,names,prefix)
    Observable(value.kind,target===nothing ? nothing : Symbol(target),extra===nothing ? nothing : Symbol(extra))
end

"""Return the design's resolved observations with hierarchy-qualified targets."""
function observations(design::CircuitDesign)
    output=NamedTuple[]
    function append_body!(body,names,prefix)
        for entry in body.observations
            resolved=_resolved_observation(entry.value,body,names,prefix)
            observation_name=entry.name===nothing ? nothing : Symbol(isempty(prefix) ? entry.name : string(prefix,'.',entry.name))
            push!(output,(name=observation_name,observable=resolved))
        end
    end
    append_body!(design.root_ir,design.names,"")
    for record in design.root.records
        template=design.templates.templates[Int(record.template)]
        append_body!(template.body,template.names,string(InstancePath(_path_segments(design,record.path))))
    end
    output
end
observations(result::SimulationResult)=observations(result.compiled.design)

function _named_observable(result,name)
    target=Symbol(name)
    found=findall(entry->entry.name===target,observations(result))
    isempty(found)&&return nothing
    length(found)==1||throw(ArgumentError("observation name $(name) is ambiguous; use a hierarchy-qualified name"))
    observations(result)[only(found)].observable
end

"""Evaluate a named design observation from a simulation result."""
function observation(result::SimulationResult,name::Union{Symbol,String})
    observable=_named_observable(result,name)
    observable===nothing&&throw(_lookup_error(:observation,name,String[string(entry.name) for entry in observations(result) if entry.name!==nothing]))
    _observable(result,observable)
end

function voltage(r::SimulationResult,name::Union{Symbol,String})
    index=_hierarchical_net_index(r.compiled,name)
    if index===nothing
        observable=_named_observable(r,name)
        observable===nothing&&throw(_lookup_error(:net,name,_net_names(r.compiled)))
        observable.kind===:voltage||throw(ArgumentError("named observation $(name) is not a voltage"))
        return _observable(r,observable)
    end
    _unknown_trace(r,index)
end
voltage(r::SimulationResult,a::Union{Symbol,String},b::Union{Symbol,String})=voltage(r,a)-voltage(r,b)
function current(r::SimulationResult,name::Union{Symbol,String},branch=nothing)
    located=_hierarchical_device(r.compiled,name); located===nothing&&throw(_lookup_error(:device,name,_device_names(r.compiled)))
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
    throw(ArgumentError("current is not implemented for device $(name) of kind $(kind)"))
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
    located=_hierarchical_device(r.compiled,name); located===nothing&&throw(_lookup_error(:device,name,_device_names(r.compiled)))
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
    (terminal(1)-terminal(2)).*current(r,name)
end

function charge(r::SimulationResult,name::Union{Symbol,String})
    located=_hierarchical_device(r.compiled,name); located===nothing&&throw(_lookup_error(:device,name,_device_names(r.compiled)))
    batch,device=located; kind=_batch_kind(batch)
    voltage_values=_unknown_trace(r,_batch_terminal(batch,1,device))-_unknown_trace(r,_batch_terminal(batch,2,device))
    kind===:capacitor&&return batch.parameters[device].value.*voltage_values
    kind===:diode&&return map(value->charge(batch.parameters[device].model,real(value);
        temperature=get(r.stats,:temperature,300.)),voltage_values)
    throw(ArgumentError("charge is not available for device $(name)"))
end

function state(r::SimulationResult,name::Union{Symbol,String},state_name::Symbol)
    located=_hierarchical_device(r.compiled,name); located===nothing&&throw(_lookup_error(:device,name,_device_names(r.compiled)))
    batch,device=located; batch isa PrimitiveBatch||throw(KeyError((name,state_name)))
    contract=device_contract(_batch_kind(batch)); state_index=findfirst(==(state_name),contract.states)
    state_index===nothing&&throw(KeyError((name,state_name)))
    _unknown_trace(r,batch.state_unknowns[device][state_index])
end
function trace(result,x)
    x isa Observable&&return _observable(result,x)
    named=_named_observable(result,x)
    named===nothing ? voltage(result,x) : _observable(result,named)
end
_observable_name(value)=value isa AbstractNode ? value.name : value
_observable(r,o::Observable)=o.kind===:voltage ?
    (o.extra===nothing ? voltage(r,_observable_name(o.target)) :
        voltage(r,_observable_name(o.target),_observable_name(o.extra))) :
    o.kind===:current ? current(r,_observable_name(o.target),o.extra) :
    o.kind===:power ? power(r,_observable_name(o.target)) :
    o.kind===:charge ? charge(r,_observable_name(o.target)) :
    o.kind===:state ? state(r,_observable_name(o.target),Symbol(o.extra)) :
    throw(ArgumentError("unsupported observation kind $(o.kind)"))
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
    located=_hierarchical_device(r.compiled,name); located===nothing&&throw(_lookup_error(:device,name,_device_names(r.compiled)))
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
