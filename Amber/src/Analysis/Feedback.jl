abstract type AbstractLoopProbe end

struct VoltageLoopProbe <: AbstractLoopProbe
    source::Symbol
    response::Observable
    sign::Float64
    function VoltageLoopProbe(source, response; sign = -1.0)
        return new(Symbol(source), _as_observable(response), Float64(sign))
    end
end

struct CurrentLoopProbe <: AbstractLoopProbe
    source::Symbol
    response::Observable
    sign::Float64
    function CurrentLoopProbe(source, response; sign = -1.0)
        return new(Symbol(source), _as_observable(response), Float64(sign))
    end
end

struct LoopGainResult
    response::LinearFrequencyResponse
    values::Vector{ComplexF64}
    margins::StabilityMargins
    probe::AbstractLoopProbe
    stats::Dict{Symbol, Any}
end
frequencies(result::LoopGainResult) = result.response.frequencies

function _validate_probe_source(circuit, probe::AbstractLoopProbe)
    expected = probe isa VoltageLoopProbe ? :voltage_source : :current_source
    cc = compile(circuit)
    located = _hierarchical_device(cc, probe.source); located === nothing&&throw(KeyError(probe.source))
    batch, device = located; _batch_kind(batch) === expected||throw(ArgumentError("$(probe.source) must be a $(expected) for $(typeof(probe))"))
    return iszero(get(batch.parameters[device], :dc, 0.0))||throw(ArgumentError("loop injection source $(probe.source) must have zero DC value to preserve the bias point"))
end

function _ideal_loop_wire(cc, name)
    located = _hierarchical_device(cc, name)
    located === nothing&&throw(KeyError(name))
    batch, device = located
    _batch_kind(batch) === :voltage_source||throw(ArgumentError("loop current must be sensed by an ideal zero-volt voltage source"))
    parameters = batch.parameters[device]
    iszero(get(parameters, :dc, 0.0))&&iszero(get(parameters, :series_resistance, 0.0))||
        throw(ArgumentError("the loop wire must be an ideal zero-DC voltage source"))
    return Int(batch.terminals[1][device]), Int(batch.terminals[2][device]), Int(batch.branch_unknowns[device])
end

function _loop_node(cc, name)
    name isa AbstractNode&&(name = name.name)
    index = _hierarchical_net_index(cc, name)
    index === nothing&&throw(KeyError(name))
    return Int(index)
end

function _loop_terminals(cc, probe::VoltageLoopProbe)
    p, n, branch = _ideal_loop_wire(cc, probe.source)
    probe.response.kind === :voltage||throw(ArgumentError("VoltageLoopProbe requires a voltage at either end of the probe"))
    measured = _loop_node(cc, probe.response.target)
    measured in (p, n)||throw(ArgumentError("probe voltage must refer to an endpoint of the loop wire"))
    reference = probe.response.extra === nothing ? 0 : _loop_node(cc, probe.response.extra)
    reference in (p, n)&&throw(ArgumentError("loop reference must be distinct from both ends of the loop wire"))
    return p, n, branch, reference
end

function _loop_terminals(cc, probe::CurrentLoopProbe)
    probe.response.kind === :current||throw(ArgumentError("CurrentLoopProbe requires current(:Sense), where Sense is a zero-volt series source"))
    p, n, branch = _ideal_loop_wire(cc, probe.response.target)
    batch, device = _hierarchical_device(cc, probe.source)
    a, b = (Int(batch.terminals[j][device]) for j in 1:2)
    reference = if a in (p, n)&&!(b in (p, n))
        b
    elseif b in (p, n)&&!(a in (p, n))
        a
    else
        throw(ArgumentError("current probe must connect one end of the sensed loop wire to a separate reference"))
    end
    return p, n, branch, reference
end

"""
    loop_gain(circuit, frequencies; probe, ...)

Compute the two-injection return ratio of a single-ended loop (Tian et al.,
2001), with return difference `1 + L`. The zero-volt series wire must intersect
all return paths of the loop being studied. The method includes loading and
reverse transmission and leaves the DC equations intact.

`VoltageLoopProbe(:Wire, voltage(:end_node, :reference))` identifies the wire
and reference (ground if omitted). `CurrentLoopProbe(:Injection, current(:Wire))`
uses an additional zero-DC current source between a wire endpoint and reference.
`sign=-1` is the standard negative-feedback convention; `sign=1` reverses L.
`closed_loop_response(result)` is the normalized complementary sensitivity,
not an arbitrary circuit input/output transfer.
"""
function loop_gain(circuit, frequency_specification::Union{Pair, AbstractVector}; probe::AbstractLoopProbe, points = 100, scale = :log, temperature = 300.0, kw...)
    _validate_probe_source(circuit, probe)
    probe.sign in (-1.0, 1.0)||throw(ArgumentError("loop probe sign must be -1 or 1"))
    cc = compile(circuit)
    p, n, branch, reference = _loop_terminals(cc, probe)
    p != n||throw(ArgumentError("loop wire must connect distinct nodes"))
    bias = _require_converged(operating_point(cc; temperature, kw...), "loop-gain operating point")
    g, c = _static_dynamic_jacobians(cc, bias.values[:, 1]; temperature, mode = :dc)
    fs = _small_signal_frequencies(frequency_specification; points, scale)
    excitation = zeros(ComplexF64, cc.n, 2)
    excitation[branch, 1] = 1.0 # unit series voltage
    p > 0&&(excitation[p, 2] += 1.0) # unit current into the joined port
    reference > 0&&(excitation[reference, 2] -= 1.0)
    values = ComplexF64[]
    for frequency in fs
        response = _solve_linear(
            g + im * 2π * frequency * c, excitation,
            "loop-gain matrix is singular at $(frequency) Hz"
        )
        voltage(column) = (p == 0 ? 0.0 : response[p, column]) -
            (reference == 0 ? 0.0 : response[reference, column])
        a = voltage(1); b = response[branch, 2]
        product = response[branch, 1] * voltage(2)
        # For the cut-port Y matrix, S=sum(Y):
        # a=(Y12+Y22)/S, b=(Y21+Y22)/S, product=-det(Y)/S².
        # Hence diagonal=(Y11+Y22)/S and L=(Y12+Y21)/(Y11+Y22).
        # This expression also handles ideal sources for which Y does not exist.
        diagonal = 1 - a - b + 2a * b - 2product
        iszero(diagonal)&&throw(LinearSolveError("loop return ratio has a pole at $(frequency) Hz"))
        push!(values, -probe.sign * (a + b - 2a * b + 2product) / diagonal)
    end
    stats = Dict{Symbol, Any}(
        :bias_preserved => true, :source => probe.source,
        :method => :tian_two_injection, :reference_index => reference, :warnings => String[]
    )
    wrapped = LinearFrequencyResponse(fs, reshape(values, 1, 1, :), [String(probe.source)], [probe.response], stats)
    margins = stability_margins(wrapped)
    return LoopGainResult(wrapped, values, margins, probe, stats)
end

loop_sensitivity(result::LoopGainResult) = sensitivity(result.values)
closed_loop_response(result::LoopGainResult) = complementary_sensitivity(result.values)
gain_margin(result::LoopGainResult) = result.margins.gain_margin
phase_margin(result::LoopGainResult) = result.margins.phase_margin
provenance(result::LoopGainResult) = Dict(:amber_version => v"0.1.0", :analysis => "LoopGain", :statistics => copy(result.stats), :unit_system => :SI, :warnings => copy(result.stats[:warnings]))
report(result::LoopGainResult) = Dict(:analysis => "LoopGain", :margins => result.margins, :statistics => copy(result.stats))
