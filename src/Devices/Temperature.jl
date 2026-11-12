"""Temperature policy in kelvin. An absolute instance temperature overrides its offset.

This policy resolves temperatures; it does not imply that every model implements
all physical temperature effects. Pass `device_temperature(policy)` to analyses.
"""
struct TemperaturePolicy
    ambient::Float64
    nominal::Float64
    instance::Union{Nothing,Float64}
    offset::Float64
    function TemperaturePolicy(; ambient=300.0, nominal=300.0, instance=nothing, offset=0.0)
        a = Float64(_si_value(ambient, Unitful.K)); n = Float64(_si_value(nominal, Unitful.K))
        i = instance === nothing ? nothing : Float64(_si_value(instance, Unitful.K))
        d = Float64(_si_value(offset, Unitful.K))
        all(isfinite, (a,n,d)) && a > 0 && n > 0 || throw(ArgumentError("temperatures must be finite and positive; offset must be finite"))
        t = i === nothing ? a+d : i
        isfinite(t) && t > 0 || throw(ArgumentError("resolved device temperature must be finite and positive"))
        new(a,n,i,d)
    end
end
device_temperature(policy::TemperaturePolicy) = policy.instance === nothing ? policy.ambient + policy.offset : policy.instance
