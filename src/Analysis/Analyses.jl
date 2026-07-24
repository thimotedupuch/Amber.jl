abstract type AbstractAnalysis end

Base.@kwdef struct MatchedGroup
    name::Symbol
    sigma_vbe::Float64=0.
    sigma_log_beta::Float64=0.
    correlation::Float64=0.
end
matched_group(name::Symbol;kw...)=MatchedGroup(;name,kw...)
struct Differential
    positive::Symbol
    negative::Symbol
end
struct OperatingPoint <: AbstractAnalysis end

Base.@kwdef struct Transient <: AbstractAnalysis
    interval::Pair{Float64,Float64}
    saveat::Union{Nothing,Float64}=nothing
    max_step::Union{Nothing,Float64}=nothing
    method::Symbol=:bdf2
    adaptive::Union{Nothing,Bool}=nothing
    overrides::Any=nothing
end
Transient(p::Pair;kw...)=Transient(interval=Float64(first(p))=>Float64(last(p));kw...)

Base.@kwdef struct SmallSignal <: AbstractAnalysis
    frequencies::Pair{Float64,Float64}
    points::Int=100
    scale::Symbol=:log
    source::Union{Nothing,Symbol}=nothing
end
SmallSignal(p::Pair;kw...)=SmallSignal(frequencies=Float64(first(p))=>Float64(last(p));kw...)

function _override_pairs(overrides)
    overrides===nothing&&return Pair{Symbol,Any}[]
    overrides isa NamedTuple&&return [Symbol(key)=>value for (key,value) in pairs(overrides)]
    overrides isa AbstractDict&&return [Symbol(key)=>value for (key,value) in pairs(overrides)]
    overrides isa Pair&&return [Symbol(first(overrides))=>last(overrides)]
    [Symbol(first(item))=>last(item) for item in overrides]
end

function _apply_overrides!(cc::CompiledCircuit,overrides)
    saved=Tuple{Component,Symbol,Any,Symbol}[]
    for (path,value) in _override_pairs(overrides)
        parts=split(String(path),'.'); length(parts)>=2||throw(ArgumentError("override paths must have the form Component.parameter"))
        component_name=Symbol(join(parts[1:end-1],'.')); key=Symbol(parts[end])
        component_index=findfirst(x->x.name===component_name,cc.circuit.components)
        component_index===nothing&&throw(KeyError(path)); component=cc.circuit.components[component_index]
        if haskey(component.parameters,key)
            push!(saved,(component,key,component.parameters[key],:parameter)); component.parameters[key]=value
        elseif haskey(component.parameters,:model)&&haskey(component.parameters[:model].data,key)
            model=component.parameters[:model]; push!(saved,(component,:model,model,:parameter))
            component.parameters[:model]=typeof(model)((;model.data...,key=>value))
        else
            throw(KeyError(path))
        end
    end
    saved
end

function _restore_overrides!(saved)
    for (component,key,value,_) in reverse(saved); component.parameters[key]=value end
end
