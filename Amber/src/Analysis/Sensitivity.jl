"""Nominal metric value and derivatives in the selected metric units per SI parameter unit."""
struct SensitivityResult{T}
    value::T
    derivatives::Dict{String,T}
end

Base.getindex(result::SensitivityResult, parameter::Union{Symbol,AbstractString}) =
    result.derivatives[String(parameter)]

struct TransferMetric
    input::Union{Observable,Symbol,String}
    output::Observable
end

struct TransferAt{M}
    transfer::TransferMetric
    frequency::Float64
    degrees::Bool
end

"""Describe an observable transfer for use in parameter sensitivity."""
transfer(pair::Pair{<:Union{Observable,Symbol,String},Observable}) =
    TransferMetric(first(pair), last(pair))

function _transfer_at(::Val{M}, metric, at; degrees = false) where {M}
    frequency = Float64(_si_value(at, Unitful.Hz))
    isfinite(frequency) && frequency > 0 ||
        throw(AnalysisValidationError("sensitivity frequency must be finite and positive"))
    return TransferAt{M}(metric, frequency, degrees)
end

"""Select the magnitude of a transfer at a positive frequency (Hz or Unitful)."""
magnitude(metric::TransferMetric; at) = _transfer_at(Val(:magnitude), metric, at)

"""Select the principal phase at a frequency, in radians or degrees."""
phase(metric::TransferMetric; at, degrees = false) =
    _transfer_at(Val(:phase), metric, at; degrees)

"""Select the amplitude gain in decibels at a frequency."""
db20(metric::TransferMetric; at) = _transfer_at(Val(:db20), metric, at)

_transfer_value(metric::TransferAt{:magnitude}, gain) = abs(gain)
_transfer_value(metric::TransferAt{:phase}, gain) = metric.degrees ? rad2deg(angle(gain)) : angle(gain)
_transfer_value(metric::TransferAt{:db20}, gain) = db20(gain)

_transfer_direction(metric::TransferAt{:magnitude}, gain, direction) =
    real(conj(gain / abs(gain)) * direction)
function _transfer_direction(metric::TransferAt{:phase}, gain, direction)
    derivative = imag(direction / gain)
    return metric.degrees ? rad2deg(derivative) : derivative
end
_transfer_direction(metric::TransferAt{:db20}, gain, direction) =
    (20 / log(10)) * real(direction / gain)

function _sensitivity_jvp(f, primals, tangents)
    cache = Mooncake.prepare_derivative_cache(f, primals...)
    result = Mooncake.value_and_derivative!!(
        cache, Mooncake.Dual(f, Mooncake.zero_tangent(f)),
        map(Mooncake.Dual, primals, tangents)...
    )
    return Mooncake.tangent(result)
end

function _sensitivity_parameter_direction(cc, selector)
    handle = parameter_handle(cc, selector)
    batches = cc.parameters.batches
    rates = Dict{ParameterLocation,Float64}()
    nominal = nothing
    for (batch, devices) in handle.locations, device in devices
        location = ParameterLocation(batch, device, handle.selector[4])
        value = _parameter_at(batches, location)
        value isa AbstractFloat && isfinite(value) ||
            throw(ArgumentError("sensitivity requires a finite real floating-point parameter: $(selector)"))
        nominal === nothing && (nominal = value)
        value == nominal ||
            throw(ArgumentError("sensitivity requires one nominal value across the selector: $(selector)"))
        rates[location] = 1.0
    end
    # Apply the standard update at the nominal value to check structural fields,
    # read-only targets and the validity of retained expansions.
    with_parameters(cc, handle => nominal)
    graph = cc.parameters.dependency_graph
    for index in graph.order
        rule = graph.rules[index]
        haskey(rates, rule.source) || continue
        x = Float64(_parameter_at(batches, rule.source))
        derive = y -> _derived_parameter_value(rule, y)
        rates[rule.target] = _sensitivity_jvp(derive, (x,), (rates[rule.source],))
    end
    return rates
end

function _sensitivity_batch_stamps(batch, state, slots, temperature, storage)
    residual = zeros(length(state))
    static = storage ? zeros(slots) : nothing
    dynamic = storage ? zeros(slots) : nothing
    sink = (; residual, jacobian = (; nzval = static),
        storage = zeros(length(state)), storage_jacobian = (; nzval = dynamic))
    _assemble_batch!(sink, batch, state, zeros(length(state)), 0.0, 0.0, :dc, 1.0, temperature)
    storage && _storage_batch!(sink, batch, state, temperature)
    return residual, static, dynamic
end

# Selectors and derived parameters have already passed the standard update
# validation. Apply only the numerical update in the differentiated kernel.
function _sensitivity_batch(batch::ResistorBatch, device, ::Val{:value}, value)
    conductance = copy(batch.conductance)
    parameters = copy(batch.parameters)
    conductance[device], parameters[device] =
        _resistor_parameter_values(parameters[device], eltype(conductance), value)
    return ResistorBatch(batch.p, batch.n, conductance, parameters,
        batch.residual_slots, batch.jacobian_slots, batch.locators)
end

function _sensitivity_batch(batch::PrimitiveBatch{K,N,P}, device, ::Val{F}, value) where {K,N,P,F}
    parameters = copy(batch.parameters)
    parameters[device] = _primitive_parameter_values(_batch_kind(batch), parameters[device], F, value)
    return PrimitiveBatch{K,N,P}(batch.terminals, parameters, batch.residual_slots,
        batch.jacobian_slots, batch.branch_unknowns, batch.control_unknowns, batch.state_unknowns, batch.locators)
end

function _sensitivity_parameter_stamp(batch, device, field, value, rate, state, slots, temperature, storage)
    stamp = function (x)
        updated = _sensitivity_batch(batch, device, field, x)
        return _sensitivity_batch_stamps(updated, state, slots, temperature, storage)
    end
    return _sensitivity_jvp(stamp, (value,), (typeof(value)(rate),))
end

function _sensitivity_parameter_stamps(cc, rates, state, slots, temperature, storage)
    residual = zeros(length(state))
    static = zeros(storage ? slots : 0)
    dynamic = similar(static)
    fill!(dynamic, 0)
    for (location, rate) in rates
        iszero(rate) && continue
        batch = cc.parameters.batches[location.batch]
        location.field === :ac && _batch_kind(batch) in (:voltage_source, :current_source) && continue
        value = _parameter_at(cc.parameters.batches, location)
        derivative = _sensitivity_parameter_stamp(batch, location.device, Val(location.field),
            value, rate, state, slots, temperature, storage)
        residual .+= derivative[1]
        if storage
            static .+= derivative[2]
            dynamic .+= derivative[3]
        end
    end
    return residual, static, dynamic
end

function _sensitivity_state_stamps!(static, dynamic, cc, state, direction, temperature)
    all(iszero, direction) && return
    for batch in cc.parameters.batches
        _linear_batch(batch) && continue
        stamp = let batch = batch, slots = length(static), temperature = temperature
            x -> _sensitivity_batch_stamps(batch, x, slots, temperature, true)
        end
        derivative = _sensitivity_jvp(stamp, (state,), (direction,))
        static .+= derivative[2]
        dynamic .+= derivative[3]
    end
    return
end

function _sensitivity_excitation(cc, rates, source)
    direction = zeros(ComplexF64, cc.n)
    for (location, rate) in rates
        location.field === :ac || continue
        batch = cc.parameters.batches[location.batch]
        _batch_kind(batch) in (:voltage_source, :current_source) || continue
        path = _parameter_device_path(cc.design, batch.locators[location.device])
        source === nothing || path == String(source) || continue
        direction .+= rate .* _unit_source_excitation(cc, path)
    end
    return direction
end

# An observable is either a scaled state projection or a direct source value.
# Its coefficient may itself depend on a selected parameter.
struct SensitivityObservable{T}
    selector::Union{Nothing,Vector{Float64}}
    coefficient::T
    parameter::Union{Nothing,ParameterLocation}
    slope::Float64
end

SensitivityObservable(selector) = SensitivityObservable(selector, 1.0, nothing, 0.0)

function _sensitivity_projection(cc, positive, negative = 0)
    selector = zeros(cc.n)
    positive > 0 && (selector[positive] += 1)
    negative > 0 && (selector[negative] -= 1)
    return selector
end

_sensitivity_observable_value(metric::SensitivityObservable, state) =
    metric.coefficient * (metric.selector === nothing ? 1 : dot(metric.selector, state))

function _sensitivity_observable_direction(metric::SensitivityObservable, state, direction, rates)
    dcoefficient = metric.parameter === nothing ? 0.0 : metric.slope * get(rates, metric.parameter, 0.0)
    metric.selector === nothing && return dcoefficient
    return metric.coefficient * dot(metric.selector, direction) + dcoefficient * dot(metric.selector, state)
end

function _sensitivity_device(cc, name)
    located = _hierarchical_device(cc, name)
    located === nothing && throw(_lookup_error(:device, name, _device_names(cc)))
    batch, device = located
    index = findfirst(candidate -> candidate === batch, cc.parameters.batches)
    return index, batch, device
end

function _sensitivity_current(cc, index, batch, device, source, ac)
    kind = _batch_kind(batch)
    if batch isa PrimitiveBatch && batch.branch_unknowns[device] != 0
        return SensitivityObservable(_sensitivity_projection(cc, batch.branch_unknowns[device]))
    elseif kind === :current_source
        path = _parameter_device_path(cc.design, batch.locators[device])
        ac && source !== nothing && String(source) != path &&
            return SensitivityObservable(nothing, 0.0, nothing, 0.0)
        field = ac ? :ac : :dc
        return SensitivityObservable(nothing, get(batch.parameters[device], field, 0.0),
            ParameterLocation(index, device, field), 1.0)
    end
    if kind in (:resistor, :conductance, :vccs)
        selector = _sensitivity_projection(cc, _batch_terminal(batch, 1, device),
            _batch_terminal(batch, 2, device))
        field = kind === :vccs ? :gm : :value
    elseif kind === :cccs
        selector = _sensitivity_projection(cc, batch.control_unknowns[device])
        field = :gain
    else
        throw(ArgumentError("current sensitivity is unavailable for devices of kind $(kind)"))
    end
    location = ParameterLocation(index, device, field)
    value = _parameter_at(cc.parameters.batches, location)
    coefficient = kind === :resistor ? batch.conductance[device] : value
    slope = kind === :resistor ? -coefficient^2 : 1.0
    return SensitivityObservable(selector, coefficient, location, slope)
end

function _sensitivity_observable(cc, observable; source = nothing, ac = false)
    if observable.kind in (:voltage, :state)
        return SensitivityObservable(_linear_output_selector(cc, observable))
    elseif observable.kind === :current
        index, batch, device = _sensitivity_device(cc, _observable_name(observable.target))
        return _sensitivity_current(cc, index, batch, device, source, ac)
    end
    throw(ArgumentError("transfer sensitivity requires a voltage, internal state, or supported current"))
end

function _sensitivity_dc_observable(cc, observable)
    observable.kind === :power || return _sensitivity_observable(cc, observable)
    index, batch, device = _sensitivity_device(cc, _observable_name(observable.target))
    current = _sensitivity_current(cc, index, batch, device, nothing, false)
    first_terminal = _batch_kind(batch) in (:vccs, :vcvs) ? 3 : 1
    voltage = SensitivityObservable(_sensitivity_projection(cc,
        _batch_terminal(batch, first_terminal, device), _batch_terminal(batch, first_terminal + 1, device)))
    return voltage, current
end

_sensitivity_observable_value(metric::Tuple, state) =
    _sensitivity_observable_value(metric[1], state) * _sensitivity_observable_value(metric[2], state)

function _sensitivity_observable_direction(metric::Tuple, state, direction, rates)
    voltage, current = metric
    return _sensitivity_observable_value(voltage, state) *
        _sensitivity_observable_direction(current, state, direction, rates) +
        _sensitivity_observable_value(current, state) *
        _sensitivity_observable_direction(voltage, state, direction, rates)
end

function _sensitivity_factor(system, solver, context)
    return try
        _new_factorization(system, solver.linear_solver)
    catch error
        error isa LinearAlgebra.SingularException || rethrow()
        throw(LinearSolveError(context))
    end
end

"""
    sensitivity(circuit; metric, parameters, source=nothing, temperature=300, solver=SolverOptions())

Evaluate a scalar metric and its local derivatives with respect to numerical
parameter selectors, in SI units. Use a voltage or internal-state observable such as
`voltage(:out)` for DC or `magnitude(transfer(:V1 => voltage(:out)); at=1kHz)`
for AC. A named independent source normalizes by its excitation phasor.
With `transfer(voltage(:in) => voltage(:out))`, normalization uses the input
observable and `source` selects the AC excitation as in `small_signal`.
When the source is inferred, the nominal active source is held fixed.
Selectors require finite floating-point values and a common nominal value
when they match several devices.

Mooncake differentiates the assembly at the converged bias. Amber reuses the
nominal linear systems to propagate each parameter direction. This is a local
derivative on the current operating branch. Zero AC normalization or zero
transfer gain is outside the supported differentiable domain.
"""
function sensitivity(circuit::Union{CircuitDesign,CompiledCircuit}; metric, parameters, source = nothing, temperature = 300.0, solver = SolverOptions(), kw...)
    cc = compile(circuit)
    selectors = String.(collect(parameters))
    isempty(selectors) && throw(ArgumentError("select at least one sensitivity parameter"))
    allunique(selectors) || throw(ArgumentError("sensitivity parameter selectors must be unique"))
    directions = [_sensitivity_parameter_direction(cc, selector) for selector in selectors]
    temperature = Float64(_si_value(temperature, Unitful.K))
    return _parameter_sensitivity(cc, metric, selectors, directions; source, temperature, solver, kw...)
end

function _parameter_sensitivity(cc, metric::Observable, selectors, directions; source, temperature, solver, kw...)
    source === nothing || throw(ArgumentError("source is only used for AC sensitivity"))
    output = _sensitivity_dc_observable(cc, metric)
    op = _require_converged(operating_point(cc; temperature, solver, kw...), "sensitivity operating point")
    bias = op.values[:, 1]
    _, jacobian = residual_jacobian(cc, bias, bias, 0.0, 0.0; mode = :dc, temperature)
    factor = _sensitivity_factor(jacobian, solver, "DC sensitivity Jacobian is singular")
    derivatives = Dict{String,Float64}()
    for (selector, rates) in zip(selectors, directions)
        residual, _, _ = _sensitivity_parameter_stamps(cc, rates, bias, 0, temperature, false)
        direction = -(factor \ residual)
        derivatives[selector] = _sensitivity_observable_direction(output, bias, direction, rates)
    end
    return SensitivityResult(_sensitivity_observable_value(output, bias), derivatives)
end

function _parameter_sensitivity(cc, metric::TransferAt, selectors, directions; source, temperature, solver, kw...)
    input = metric.transfer.input
    named_source = !(input isa Observable)
    if named_source
        source === nothing || String(source) == String(input) ||
            throw(ArgumentError("source must match the named transfer input"))
        source = input
    end
    op = _require_converged(operating_point(cc; temperature, solver, kw...), "sensitivity operating point")
    bias = op.values[:, 1]
    _, active = _small_signal_sources(cc, source)
    source === nothing && length(active) == 1 && (source = only(active))
    output = _sensitivity_observable(cc, metric.transfer.output; source, ac = true)
    excitation = ac_excitation(cc; source)
    static, dynamic = _static_dynamic_jacobians(cc, bias; mode = :dc, temperature)
    dc_factor = _sensitivity_factor(static, solver, "DC sensitivity Jacobian is singular")
    jw = im * 2π * metric.frequency
    system = SparseMatrixCSC(cc.n, cc.n, static.colptr, static.rowval, static.nzval .+ jw .* dynamic.nzval)
    ac_factor = _sensitivity_factor(system, solver, "AC sensitivity matrix is singular")
    phasor = ac_factor \ excitation
    if named_source
        selector = _unit_source_excitation(cc, source)
        denominator_metric = SensitivityObservable(selector ./ sum(abs2, selector))
    else
        denominator_metric = _sensitivity_observable(cc, input; source, ac = true)
    end
    denominator = _sensitivity_observable_value(denominator_metric, named_source ? excitation : phasor)
    isfinite(denominator) && !iszero(denominator) ||
        throw(AnalysisValidationError("transfer input must be finite and nonzero"))
    gain = _sensitivity_observable_value(output, phasor) / denominator
    isfinite(gain) && !iszero(gain) ||
        throw(AnalysisValidationError("transfer sensitivity requires a finite nonzero gain"))
    metric isa TransferAt{:phase} && iszero(imag(gain)) && real(gain) < 0 &&
        throw(AnalysisValidationError("principal phase sensitivity is undefined on the negative real axis"))
    derivatives = Dict{String,Float64}()
    for (selector, rates) in zip(selectors, directions)
        residual, dg, dc = _sensitivity_parameter_stamps(cc, rates, bias, nnz(static), temperature, true)
        direction = -(dc_factor \ residual)
        _sensitivity_state_stamps!(dg, dc, cc, bias, direction, temperature)
        db = _sensitivity_excitation(cc, rates, source)
        dsystem = SparseMatrixCSC(cc.n, cc.n, static.colptr, static.rowval, dg .+ jw .* dc)
        dphasor = ac_factor \ (db - dsystem * phasor)
        ddenominator = _sensitivity_observable_direction(denominator_metric,
            named_source ? excitation : phasor, named_source ? db : dphasor, rates)
        doutput = _sensitivity_observable_direction(output, phasor, dphasor, rates)
        dgain = (doutput - gain * ddenominator) / denominator
        derivatives[selector] = _transfer_direction(metric, gain, dgain)
    end
    return SensitivityResult(_transfer_value(metric, gain), derivatives)
end
