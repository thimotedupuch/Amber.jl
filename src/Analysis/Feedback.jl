abstract type AbstractLoopProbe end

struct VoltageLoopProbe <: AbstractLoopProbe
    source::Symbol
    response::Observable
    sign::Float64
    function VoltageLoopProbe(source,response;sign=-1.)
        new(Symbol(source),_as_observable(response),Float64(sign))
    end
end

struct CurrentLoopProbe <: AbstractLoopProbe
    source::Symbol
    response::Observable
    sign::Float64
    function CurrentLoopProbe(source,response;sign=-1.)
        new(Symbol(source),_as_observable(response),Float64(sign))
    end
end

struct LoopGainResult
    response::LinearFrequencyResponse
    values::Vector{ComplexF64}
    margins::StabilityMargins
    probe::AbstractLoopProbe
    stats::Dict{Symbol,Any}
end
frequencies(result::LoopGainResult)=result.response.frequencies

function _validate_probe_source(circuit,probe::AbstractLoopProbe)
    cc=compile(circuit); index=findfirst(component->component.name===probe.source,cc.circuit.components)
    index===nothing&&throw(KeyError(probe.source)); source=cc.circuit.components[index]
    expected=probe isa VoltageLoopProbe ? :voltage_source : :current_source
    source.kind===expected||throw(ArgumentError("$(probe.source) must be a $(expected) for $(typeof(probe))"))
    iszero(get(source.parameters,:dc,0.))||throw(ArgumentError("loop injection source $(probe.source) must have zero DC value to preserve the bias point"))
end

function loop_gain(circuit,frequency_specification::Union{Pair,AbstractVector};probe::AbstractLoopProbe,points=100,scale=:log,temperature=300.,kw...)
    _validate_probe_source(circuit,probe)
    model=linearize(circuit;inputs=probe.source,outputs=probe.response,temperature,kw...)
    response=frequency_response(model,frequency_specification;points,scale)
    values=probe.sign.*vec(response.values[1,1,:])
    wrapped=LinearFrequencyResponse(response.frequencies,reshape(values,1,1,:),response.inputs,response.outputs,response.stats)
    margins=stability_margins(wrapped)
    stats=Dict{Symbol,Any}(:bias_preserved=>true,:source=>probe.source,:warnings=>String[])
    LoopGainResult(wrapped,values,margins,probe,stats)
end

loop_sensitivity(result::LoopGainResult)=sensitivity(result.values)
closed_loop_response(result::LoopGainResult)=complementary_sensitivity(result.values)
gain_margin(result::LoopGainResult)=result.margins.gain_margin
phase_margin(result::LoopGainResult)=result.margins.phase_margin
provenance(result::LoopGainResult)=Dict(:amber_version=>v"0.1.0",:analysis=>"LoopGain",:statistics=>copy(result.stats),:unit_system=>:SI,:warnings=>copy(result.stats[:warnings]))
report(result::LoopGainResult)=Dict(:analysis=>"LoopGain",:margins=>result.margins,:statistics=>copy(result.stats))
