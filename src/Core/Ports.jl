abstract type AbstractNode end

Base.@kwdef struct MatchedGroup
    name::Symbol
    sigma_vbe::Float64 = 0.0
    sigma_log_beta::Float64 = 0.0
    correlation::Float64 = 0.0
end
matched_group(name::Symbol; kw...) = MatchedGroup(; name, kw...)

struct Differential
    positive::Symbol
    negative::Symbol
end

struct Observable
    kind::Symbol
    target::Any
    extra::Any
end

"""Immutable primitive constructor output consumed by `CircuitBuilder`."""
struct PrimitiveDraft{K, T <: Tuple, P <: NamedTuple}
    terminals::T
    parameters::P
end
_draft_kind(::PrimitiveDraft{K}) where {K} = K

voltage(n::AbstractNode) = Observable(:voltage, n, nothing)
voltage(a::AbstractNode, b::AbstractNode) = Observable(:voltage, a, b)
voltage(name::Union{Symbol, String}) = Observable(:voltage, name, nothing)
voltage(a::Union{Symbol, String}, b::Union{Symbol, String}) = Observable(:voltage, a, b)
current(x, branch = nothing) = Observable(:current, x, branch)
power(x) = Observable(:power, x, nothing)
charge(x) = Observable(:charge, x, nothing)
state(x, s) = Observable(:state, x, s)

node() = error("node() is available inside @circuit; use node!(builder, name) in builder code")
ground() = error("ground() is available inside @circuit; use ground!(builder, name) in builder code")
observe(args...) = error("observe is available inside @circuit; use observe!(builder, ...) in builder code")
initial_voltage(args...) = error("initial_voltage is available inside @circuit and @subcircuit")
