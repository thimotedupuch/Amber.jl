abstract type AbstractAnalysis end

struct OperatingPoint <: AbstractAnalysis end

Base.@kwdef struct Transient <: AbstractAnalysis
    interval::Pair{Float64,Float64}
    saveat::Union{Nothing,Float64}=nothing
    max_step::Union{Nothing,Float64}=nothing
    method::Symbol=:bdf2
    adaptive::Union{Nothing,Bool}=nothing
    temperature::Float64=300.
    overrides::Any=nothing
end
Transient(p::Pair;kw...)=Transient(interval=Float64(first(p))=>Float64(last(p));kw...)

function _validate_transient(interval;saveat=nothing,max_step=nothing,method=:bdf2,event_mode=nothing,reltol=1e-6,abstol=1e-9,maxiters=120)
    t0,t1=Float64(first(interval)),Float64(last(interval))
    isfinite(t0)&&isfinite(t1)&&t1>t0||throw(AnalysisValidationError("transient interval must be finite and increasing"))
    saveat===nothing||(isfinite(saveat)&&saveat>0)||throw(AnalysisValidationError("saveat must be finite and positive"))
    max_step===nothing||(isfinite(max_step)&&max_step>0)||throw(AnalysisValidationError("max_step must be finite and positive"))
    method in (:bdf1,:bdf2)||throw(AnalysisValidationError("method must be :bdf1 or :bdf2"))
    event_mode in (nothing,:exact)||throw(AnalysisValidationError("event_mode must be nothing or :exact"))
    isfinite(reltol)&&reltol>0||throw(AnalysisValidationError("reltol must be finite and positive"))
    isfinite(abstol)&&abstol>0||throw(AnalysisValidationError("abstol must be finite and positive"))
    maxiters>0||throw(AnalysisValidationError("maxiters must be positive"))
end

function _validate_frequency_range(range,points,scale)
    low,high=Float64(first(range)),Float64(last(range))
    isfinite(low)&&isfinite(high)&&high>=low||throw(AnalysisValidationError("frequency range must be finite and increasing"))
    scale in (:log,:linear)||throw(AnalysisValidationError("frequency scale must be :log or :linear"))
    scale===:log&&low<=0&&throw(AnalysisValidationError("logarithmic frequencies must be positive"))
    points>=1||throw(AnalysisValidationError("frequency point count must be positive"))
end

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
