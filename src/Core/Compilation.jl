abstract type AbstractCompiledCircuit end

struct CompiledCircuit{P} <: AbstractCompiledCircuit
    design::CircuitDesign
    topology::HierarchicalCompiledTopology
    parameters::P
    fingerprint::String
end

const CompiledTopology = HierarchicalCompiledTopology

function Base.getproperty(compiled::CompiledCircuit,name::Symbol)
    name in (:design,:topology,:parameters,:fingerprint)&&return getfield(compiled,name)
    name===:hierarchical_topology&&return getfield(compiled,:topology)
    name===:n&&return getfield(compiled,:topology).hierarchy.unknown_count
    name===:jacobian_pattern&&return SparseMatrixCSC{Float64,Int}(getfield(compiled,:topology).pattern)
    getfield(compiled,name)
end
Base.propertynames(::CompiledCircuit,private::Bool=false)=(:design,:topology,:parameters,:fingerprint,:hierarchical_topology,:n,:jacobian_pattern)

_snapshot_compiled(compiled::CompiledCircuit)=compiled

function _materialize_parameter(value, values, netmap=nothing)
    value isa AbstractParameterExpression && return _evaluate(value, values)
    value isa LocalNetReference && return netmap === nothing ? value : netmap[Int(value.id)]
    value isa NamedTuple && return NamedTuple{keys(value)}(Tuple(_materialize_parameter(item, values, netmap) for item in value))
    value isa Tuple && return Tuple(_materialize_parameter(item, values, netmap) for item in value)
    value isa AbstractVector && return [_materialize_parameter(item, values, netmap) for item in value]
    value
end

function compile(design::CircuitDesign)
    all_diagnostics,topology,parameters=_check_and_compile(design)
    diagnostics=filter(diagnostic->diagnostic.severity===:error,all_diagnostics)
    isempty(diagnostics)||throw(CircuitValidationError(diagnostics))
    fingerprint = bytes2hex(sha1(string(design.structural_fingerprint, ':', design.parameter_fingerprint)))
    CompiledCircuit(design, topology, parameters, fingerprint)
end
compile(compiled::CompiledCircuit)=compiled

_v(values,index)=index==0 ? zero(eltype(values)) : values[index]
_thermal_voltage(temperature)=1.380649e-23*Float64(temperature)/1.602176634e-19

function _limited_exponential(argument)
    if argument>80.
        expvalue=exp(80.)
        expvalue*(1+argument-80.)-1,expvalue
    elseif argument < -80.
        expvalue=exp(-80.)
        expvalue-1,zero(expvalue)
    else
        expvalue=exp(argument)
        expvalue-1,expvalue
    end
end

function _source_value(parameters,time,mode)
    mode===:matrix&&return 0.
    mode===:dc&&return get(parameters,:dc,0.)
    waveform=get(parameters,:waveform,nothing)
    waveform===nothing ? get(parameters,:dc,0.) : waveform(time)
end

function _switch_conductance(model,control)
    if model isa SmoothSwitch
        transition=max(abs(model.transition),eps(Float64))
        fraction=(1+tanh((control-model.threshold)/transition))/2
        return fraction/model.ron+(1-fraction)/model.roff
    end
    inv(control>=model.threshold ? model.ron : model.roff)
end

function _switch_conductance_derivative(model,control)
    model isa SmoothSwitch||return 0.
    transition=max(abs(model.transition),eps(Float64))
    argument=(control-model.threshold)/transition
    .5*(1-tanh(argument)^2)/transition*(inv(model.ron)-inv(model.roff))
end

function residual(compiled::CompiledCircuit,state,derivative,time;mode=:time,source_scale=1.,gmin=0.,temperature=300.)
    workspace=SimulationWorkspace(compiled;scalar_type=eltype(state))
    copy(residual!(workspace,compiled,state,derivative,time;mode,source_scale,gmin,temperature))
end

"""Right-hand side for independent small-signal source phasors."""
function ac_excitation(compiled::CompiledCircuit;source=nothing)
    excitation=zeros(ComplexF64,compiled.n)
    selected=source===nothing ? nothing : String(source)
    for batch in compiled.parameters.batches
        kind=_batch_kind(batch)
        kind in (:voltage_source,:current_source)||continue
        for device in eachindex(batch.parameters)
            instance_name,device_name=_locator_device_name(compiled.design,batch.locators[device])
            path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
            selected!==nothing&&path!=selected&&continue
            amplitude=ComplexF64(get(batch.parameters[device],:ac,0.))
            if kind===:voltage_source
                excitation[Int(batch.branch_unknowns[device])]+=amplitude
            else
                positive=batch.terminals[1][device]; negative=batch.terminals[2][device]
                positive>0&&(excitation[Int(positive)]-=amplitude)
                negative>0&&(excitation[Int(negative)]+=amplitude)
            end
        end
    end
    excitation
end

"""Allocating compatibility wrapper around in-place residual/Jacobian assembly."""
function residual_jacobian(compiled::CompiledCircuit,state,previous,time,alpha;mode=:time,source_scale=1.,gmin=0.,temperature=300.)
    workspace=SimulationWorkspace(compiled;scalar_type=eltype(state))
    residual_values,jacobian_values=residual_jacobian!(workspace,compiled,state,previous,time,alpha;
        mode,source_scale,gmin,temperature)
    copy(residual_values),copy(jacobian_values)
end
