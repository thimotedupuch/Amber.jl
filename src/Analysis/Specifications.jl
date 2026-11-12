"""A named scalar measurement with optional inclusive physical limits.

`metric(result)` may return a Unitful quantity. Missing, nonfinite, or failed
measurements are retained as `:unresolved`, never counted as passing.
"""
struct MeasurementSpec{F,L,U}
    name::Symbol
    metric::F
    lower::L
    upper::U
    function MeasurementSpec(name, metric; lower=nothing, upper=nothing)
        lower !== nothing && upper !== nothing && lower > upper &&
            throw(ArgumentError("lower limit exceeds upper limit"))
        new{typeof(metric),typeof(lower),typeof(upper)}(Symbol(name), metric, lower, upper)
    end
end
struct MeasurementAssessment
    name::Symbol
    value::Any
    lower::Any
    upper::Any
    status::Symbol
    reason::String
end
"""Evaluate a specification, retaining exceptions as unresolved assessments."""
function assess(spec::MeasurementSpec, result)
    value = nothing
    try
        value = spec.metric(result)
        if value === nothing || ismissing(value) || !(value isa Number) || !isfinite(value) || !isreal(value)
            return MeasurementAssessment(spec.name, value, spec.lower, spec.upper, :unresolved, "measurement is not a finite real scalar")
        end
        passed = (spec.lower === nothing || value >= spec.lower) &&
            (spec.upper === nothing || value <= spec.upper)
        return MeasurementAssessment(spec.name, value, spec.lower, spec.upper,
            passed ? :pass : :fail, passed ? "within limits" : "outside limits")
    catch error
        error isa InterruptException && rethrow()
        return MeasurementAssessment(spec.name, value, spec.lower, spec.upper, :unresolved, sprint(showerror, error))
    end
end
function assess(specs::AbstractVector{<:MeasurementSpec}, result)
    names = getproperty.(specs, :name)
    allunique(names) || throw(ArgumentError("measurement names must be unique"))
    return assess.(specs, Ref(result))
end
