const _BOLTZMANN = 1.380649e-23
const _ELEMENTARY_CHARGE = 1.602176634e-19

"""
A physical noise generator and its sparse-equivalent MNA injection vector.
`psd` returns a one-sided source PSD in SI units.
"""
struct NoiseSource
    id::Symbol
    owner::Symbol
    mechanism::Symbol
    injection::Vector{ComplexF64}
    psd::Function
    correlation_group::Union{Nothing, Symbol}
end

"""A group of noise sources described by a complex correlation matrix."""
struct NoiseCorrelationGroup
    id::Symbol
    source_ids::Vector{Symbol}
    correlation::Function
end

"""Frequency-resolved contribution of one physical source to a noise result."""
struct NoiseSourceContribution
    source::Symbol
    component::Symbol
    mechanism::Symbol
    output_psd::Vector{Float64}
    input_referred_psd::Union{Nothing, Vector{Float64}}
end

struct NoiseResult
    frequencies::Vector{Float64}
    output::Observable
    input_source::Union{Nothing, Symbol}
    output_psd::Vector{Float64}
    input_referred_psd::Union{Nothing, Vector{Float64}}
    contributions::Vector{NoiseSourceContribution}
    compiled::AbstractCompiledCircuit
    stats::Dict{Symbol, Any}
    function NoiseResult(
            frequencies, output, input_source, output_psd, input_referred_psd,
            contributions, compiled, stats
        )
        return new(
            Float64.(frequencies), deepcopy(output), input_source, Float64.(output_psd),
            input_referred_psd === nothing ? nothing : Float64.(input_referred_psd),
            contributions, _snapshot_compiled(compiled), stats
        )
    end
end

frequencies(result::NoiseResult) = result.frequencies
noise_psd(result::NoiseResult) = result.output_psd
noise_density(result::NoiseResult) = sqrt.(max.(result.output_psd, 0.0))
input_referred_noise_psd(result::NoiseResult) = result.input_referred_psd
input_referred_noise_density(result::NoiseResult) = result.input_referred_psd === nothing ?
    nothing : sqrt.(max.(result.input_referred_psd, 0.0))

function noise_contributions(result::NoiseResult; component = nothing, mechanism = nothing)
    return filter(result.contributions) do contribution
        (component === nothing||contribution.component === Symbol(component))&&
            (mechanism === nothing||contribution.mechanism === Symbol(mechanism))
    end
end

function _noise_injection(cc, positive, negative)
    vector = zeros(ComplexF64, cc.n)
    positive > 0&&(vector[positive] -= 1)
    negative > 0&&(vector[negative] += 1)
    return vector
end

function _noise_injection(cc, weights::Pair{<:Integer, <:Number}...)
    vector = zeros(ComplexF64, cc.n)
    for (index, weight) in weights
        index > 0&&(vector[index] += weight)
    end
    return vector
end

_power_law(coefficient, current, current_exponent, frequency, frequency_exponent, reference) =
    coefficient == 0 ? 0.0 : coefficient * abs(current)^current_exponent *
    (reference / frequency)^frequency_exponent

function _noise_source_psd(source, frequency, bias, time)
    value = real(source.psd(frequency, bias, time))
    isfinite(value)||throw(
        AnalysisValidationError(
            "noise source $(source.id) produced a non-finite PSD at $(frequency) Hz"
        )
    )
    value >= 0||throw(
        AnalysisValidationError(
            "noise source $(source.id) produced a negative PSD at $(frequency) Hz"
        )
    )
    return value
end

function _push_source!(sources, id, owner, mechanism, injection, psd; group = nothing)
    return push!(sources, NoiseSource(Symbol(owner, ".", id), owner, mechanism, injection, psd, group))
end

function _noise_parent_name(name::Symbol)
    text = String(name)
    suffixes = (
        ".esr", ".winding_resistance", ".series_resistance",
        ".base_resistance", ".leakage_resistance", ".package_resistance",
    )
    for suffix in suffixes
        endswith(text, suffix)&&return Symbol(text[1:(end - length(suffix))])
    end
    occursin(r"\.da\d+_resistor$", text)&&return Symbol(
        replace(
            text,
            r"\.da\d+_resistor$" => ""
        )
    )
    return name
end

function _device_noise_sources(cc, batch, device, op; temperature = 300.0)
    kind = _batch_kind(batch)
    parameters = batch.parameters[device]
    terminals = [Int(_batch_terminal(batch, index, device)) for index in 1:(batch isa ResistorBatch ? 2 : length(batch.terminals))]
    instance_name, device_name = _locator_device_name(cc.design, batch.locators[device])
    owner = Symbol(isempty(instance_name) ? device_name : string(instance_name, '.', device_name))
    sources = NoiseSource[]
    groups = NoiseCorrelationGroup[]

    if kind in (:resistor, :conductance)
        conductance = kind === :resistor ? batch.conductance[device] : Float64(parameters.value)
        injection = _noise_injection(cc, terminals[1], terminals[2])
        _push_source!(
            sources, :thermal, owner, :thermal, injection,
            (_frequency, _bias, _time) -> 4 * _BOLTZMANN * temperature * conductance
        )
        material = get(parameters, :material, nothing)
        if material isa AbstractResistorMaterial&&material.excess_noise_coefficient > 0
            current = conductance * (_v(op, terminals[1]) - _v(op, terminals[2]))
            _push_source!(
                sources, :excess, owner, :flicker, injection,
                (frequency, _bias, _time) -> _power_law(
                    material.excess_noise_coefficient,
                    current, material.excess_current_exponent, frequency,
                    material.excess_frequency_exponent, material.excess_reference_frequency
                )
            )
        end
    elseif kind === :voltage_source
        resistance = Float64(get(parameters, :series_resistance, 0.0))
        if resistance > 0
            branch = batch.branch_unknowns[device]
            _push_source!(
                sources, :series_resistance, owner, :thermal,
                _noise_injection(cc, branch => 1),
                (_frequency, _bias, _time) -> 4 * _BOLTZMANN * temperature * resistance
            )
        end
    elseif kind === :diode
        model = parameters[:model]
        voltage = _v(op, terminals[1]) - _v(op, terminals[2])
        vt = _thermal_voltage(temperature) * model.ideality
        forward = max(model.saturation_current * exp(clamp(voltage / vt, -80, 40)), 0.0)
        reverse = model.saturation_current
        avalanche = 0.0
        if isfinite(model.breakdown_voltage)
            argument = (-voltage - model.breakdown_voltage) / vt
            argument > 0&&(avalanche = model.breakdown_current * exp(clamp(argument, -80, 40)))
        end
        injection = _noise_injection(cc, terminals[1], terminals[2])
        _push_source!(
            sources, :forward_shot, owner, :shot, injection,
            (_frequency, _bias, _time) -> 2 * _ELEMENTARY_CHARGE * forward
        )
        _push_source!(
            sources, :reverse_shot, owner, :shot, injection,
            (_frequency, _bias, _time) -> 2 * _ELEMENTARY_CHARGE * reverse
        )
        isfinite(model.breakdown_voltage)&&_push_source!(
            sources, :avalanche_shot,
            owner, :avalanche, injection,
            (_frequency, _bias, _time) -> 2 * _ELEMENTARY_CHARGE * avalanche
        )
        current = forward - reverse - avalanche
        model.flicker_coefficient > 0&&_push_source!(
            sources, :flicker, owner, :flicker, injection,
            (frequency, _bias, _time) -> _power_law(
                model.flicker_coefficient, current,
                model.flicker_current_exponent, frequency, model.flicker_frequency_exponent,
                model.flicker_reference_frequency
            )
        )
    elseif kind === :npn
        model = parameters[:model]
        collector, base, emitter = terminals
        vc, vb, ve = _v(op, collector), _v(op, base), _v(op, emitter)
        vt = _thermal_voltage(temperature)
        forward = max(model.saturation_current * exp(clamp((vb - ve) / vt, -80, 40)), 0.0)
        reverse = max(model.saturation_current * exp(clamp((vb - vc) / vt, -80, 40)), 0.0)
        αf = model.forward_beta / (model.forward_beta + 1)
        αr = model.reverse_beta / (model.reverse_beta + 1)
        forward_injection = _noise_injection(cc, collector => -αf, base => -(1 - αf), emitter => 1)
        reverse_injection = _noise_injection(cc, collector => 1, base => -(1 - αr), emitter => -αr)
        _push_source!(
            sources, :forward_transport, owner, :shot, forward_injection,
            (_frequency, _bias, _time) -> 2 * _ELEMENTARY_CHARGE * forward
        )
        _push_source!(
            sources, :reverse_transport, owner, :shot, reverse_injection,
            (_frequency, _bias, _time) -> 2 * _ELEMENTARY_CHARGE * reverse
        )
        base_current = (1 - αf) * forward + (1 - αr) * reverse
        model.flicker_coefficient > 0&&_push_source!(
            sources, :base_flicker, owner, :flicker,
            _noise_injection(cc, base, emitter),
            (frequency, _bias, _time) -> _power_law(
                model.flicker_coefficient, base_current,
                model.flicker_current_exponent, frequency, model.flicker_frequency_exponent,
                model.flicker_reference_frequency
            )
        )
    elseif kind in (:nmos, :pmos)
        model = parameters[:model]
        drain, gate, source, bulk = terminals
        channel, derivatives = _mosfet_channel(
            model, kind, _v(op, drain), _v(op, gate),
            _v(op, source), _v(op, bulk); temperature
        )
        gm = abs(derivatives[2])
        noise_conductance = model isa ChargeBasedMOSFET ?
            _charge_mos_evaluate(model, kind, (_v(op, drain), _v(op, gate), _v(op, source), _v(op, bulk)); temperature).thermal_conductance : gm
        channel_id = Symbol(owner, ".channel_thermal")
        gate_id = Symbol(owner, ".induced_gate")
        group = model.induced_gate_noise_coefficient > 0 ? Symbol(owner, ".channel_gate") : nothing
        _push_source!(
            sources, :channel_thermal, owner, :thermal,
            _noise_injection(cc, drain, source),
            (_frequency, _bias, _time) -> 4 * _BOLTZMANN * temperature *
                model.channel_thermal_coefficient * noise_conductance; group
        )
        if model.induced_gate_noise_coefficient > 0
            _push_source!(
                sources, :induced_gate, owner, :gate,
                _noise_injection(cc, gate, source),
                (frequency, _bias, _time) -> 4 * _BOLTZMANN * temperature *
                    model.induced_gate_noise_coefficient * gm; group
            )
            correlation = model.gate_channel_correlation
            push!(
                groups, NoiseCorrelationGroup(
                    group, [channel_id, gate_id],
                    (_frequency, _bias, _time) -> ComplexF64[1 correlation;conj(correlation) 1]
                )
            )
        end
        model.flicker_coefficient > 0&&_push_source!(
            sources, :flicker, owner, :flicker,
            _noise_injection(cc, drain, source),
            (frequency, _bias, _time) -> _power_law(
                model.flicker_coefficient, channel,
                model.flicker_current_exponent, frequency, model.flicker_frequency_exponent,
                model.flicker_reference_frequency
            )
        )
    elseif kind === :switch
        model = parameters[:model]
        control = _v(op, terminals[3]) - _v(op, terminals[4])
        conductance = _switch_conductance(model, control)
        _push_source!(
            sources, :channel_thermal, owner, :thermal,
            _noise_injection(cc, terminals[1], terminals[2]),
            (_frequency, _bias, _time) -> 4 * _BOLTZMANN * temperature * conductance
        )
    elseif kind === :opamp
        model = parameters[:model]
        positive, negative, output, positive_rail, negative_rail = terminals
        branch = batch.branch_unknowns[device]
        state = only(batch.state_unknowns[device])
        pole = 2π * model.gain_bandwidth / max(model.dc_gain, 1.0)
        voltage_group = abs(model.voltage_current_noise_correlation) > 0 ?
            Symbol(owner, ".input_noise") : nothing
        voltage_id = Symbol(owner, ".input_voltage")
        positive_id = Symbol(owner, ".positive_input_current")
        model.input_voltage_noise_density > 0&&_push_source!(
            sources, :input_voltage, owner,
            :opamp_voltage, _noise_injection(cc, state => pole * model.dc_gain),
            (_frequency, _bias, _time) -> model.input_voltage_noise_density^2;
            group = voltage_group
        )
        model.input_voltage_noise_density > 0&&model.input_voltage_flicker_corner > 0&&
            _push_source!(
            sources, :input_voltage_flicker, owner, :flicker,
            _noise_injection(cc, state => pole * model.dc_gain),
            (frequency, _bias, _time) -> model.input_voltage_noise_density^2 *
                (model.input_voltage_flicker_corner / frequency)^
                model.input_voltage_flicker_exponent
        )
        model.positive_input_current_noise_density > 0&&_push_source!(
            sources,
            :positive_input_current, owner, :opamp_current, _noise_injection(cc, positive, negative_rail),
            (_frequency, _bias, _time) -> model.positive_input_current_noise_density^2;
            group = voltage_group
        )
        model.positive_input_current_noise_density > 0&&
            model.input_current_flicker_corner > 0&&_push_source!(
            sources,
            :positive_input_current_flicker, owner, :flicker,
            _noise_injection(cc, positive, negative_rail),
            (frequency, _bias, _time) -> model.positive_input_current_noise_density^2 *
                (model.input_current_flicker_corner / frequency)^
                model.input_current_flicker_exponent
        )
        model.negative_input_current_noise_density > 0&&_push_source!(
            sources,
            :negative_input_current, owner, :opamp_current, _noise_injection(cc, negative, negative_rail),
            (_frequency, _bias, _time) -> model.negative_input_current_noise_density^2
        )
        model.negative_input_current_noise_density > 0&&
            model.input_current_flicker_corner > 0&&_push_source!(
            sources,
            :negative_input_current_flicker, owner, :flicker,
            _noise_injection(cc, negative, negative_rail),
            (frequency, _bias, _time) -> model.negative_input_current_noise_density^2 *
                (model.input_current_flicker_corner / frequency)^
                model.input_current_flicker_exponent
        )
        if voltage_group !== nothing&&model.input_voltage_noise_density > 0&&
                model.positive_input_current_noise_density > 0
            correlation = model.voltage_current_noise_correlation
            push!(
                groups, NoiseCorrelationGroup(
                    voltage_group, [voltage_id, positive_id],
                    (_frequency, _bias, _time) -> ComplexF64[1 correlation;conj(correlation) 1]
                )
            )
        end
        if model.output_resistance > 0
            _push_source!(
                sources, :output_resistance, owner, :thermal,
                _noise_injection(cc, branch => 1),
                (_frequency, _bias, _time) -> 4 * _BOLTZMANN * temperature * model.output_resistance
            )
        end
    end
    physical_owner = _noise_parent_name(owner)
    if physical_owner !== owner
        sources = [
            NoiseSource(
                source.id, physical_owner, source.mechanism,
                source.injection, source.psd, source.correlation_group
            ) for source in sources
        ]
    end
    return sources, groups
end

function noise_sources(cc, op; temperature = 300.0)
    sources = NoiseSource[]
    groups = NoiseCorrelationGroup[]
    for batch in cc.parameters.batches
        for device in eachindex(batch.parameters)
            local_sources, local_groups = _device_noise_sources(cc, batch, device, op; temperature)
            append!(sources, local_sources)
            append!(groups, local_groups)
        end
    end
    return sources, groups
end

function _validate_correlation(matrix, group_id; atol = 1.0e-10)
    size(matrix, 1) == size(matrix, 2)||throw(
        AnalysisValidationError(
            "noise correlation group $(group_id) is not square"
        )
    )
    all(isfinite, real.(matrix))&&all(isfinite, imag.(matrix))||
        throw(AnalysisValidationError("noise correlation group $(group_id) is not finite"))
    norm(matrix - matrix', Inf) <= atol * max(norm(matrix, Inf), 1.0)||
        throw(AnalysisValidationError("noise correlation group $(group_id) is not Hermitian"))
    minimum(eigvals(Hermitian((matrix + matrix') / 2))) >= -atol * max(norm(matrix, Inf), 1.0)||
        throw(AnalysisValidationError("noise correlation group $(group_id) is not positive semidefinite"))
    return nothing
end

function _frequency_grid(specification; points = 100, scale = :log)
    specification isa AbstractVector&&return _validate_frequency_grid(specification)
    _validate_frequency_range(specification, points, scale)
    return first(specification) == last(specification) ? [Float64(first(specification))] :
        scale === :log ? collect(
            10 .^ Base.range(
                log10(first(specification)),
                log10(last(specification)), length = points
            )
        ) :
        collect(Base.range(first(specification), last(specification), length = points))
end

function _noise_output_direct(cc, observable, source)
    observable.kind === :current||return 0.0
    target = String(observable.target)
    located = _hierarchical_device(cc, target)
    located === nothing&&return 0.0
    batch, _ = located
    _batch_kind(batch) in (:resistor, :conductance)||return 0.0
    return startswith(String(source.id), target * ".") ? 1.0 : 0.0
end

function noise(
        c, frequency_specification; output, input = nothing, points = 100, scale = :log,
        temperature = 300.0, contributions = true, bias = nothing, operating_point_options...
    )
    isfinite(temperature)&&temperature > 0||
        throw(AnalysisValidationError("noise temperature must be finite and positive"))
    frequencies = _frequency_grid(frequency_specification; points, scale)
    any(iszero, frequencies)&&throw(
        AnalysisValidationError(
            "stationary noise frequencies must be positive because power-law noise is undefined at DC"
        )
    )
    cc = compile(c)
    diagnostics = filter(diagnostic -> diagnostic.severity === :error, check(cc.design))
    isempty(diagnostics)||throw(CircuitValidationError(diagnostics))
    if bias === nothing
        point = _require_converged(
            operating_point(cc; temperature, operating_point_options...),
            "noise operating point"
        ).values[:, 1]
    elseif bias isa SimulationResult
        _require_converged(bias, "supplied noise bias")
        bias.compiled.fingerprint == cc.fingerprint||throw(
            ArgumentError(
                "supplied noise bias belongs to a different compiled circuit"
            )
        )
        point = bias.values[:, 1]
    else
        point = Float64.(bias)
    end
    length(point) == cc.n||throw(DimensionMismatch("noise bias point does not match the compiled circuit"))
    all(isfinite, point)||throw(ArgumentError("noise bias point must be finite"))
    output_observable = _as_observable(output)
    selector = ComplexF64.(_linear_output_selector(cc, output_observable))
    sources, groups = noise_sources(cc, point; temperature)
    source_index = Dict(source.id => index for (index, source) in enumerate(sources))
    grouped_ids = Set(id for group in groups for id in group.source_ids)
    output_psd = zeros(Float64, length(frequencies))
    source_output = [zeros(Float64, length(frequencies)) for _ in sources]
    gains = input === nothing ? nothing : zeros(Float64, length(frequencies))
    corrections = 0
    Jz, Jd = _static_dynamic_jacobians(cc, point; mode = :dc, temperature)
    excitation = input === nothing ? nothing : _unit_source_excitation(cc, Symbol(input))
    for (frequency_index, frequency) in enumerate(frequencies)
        system = Jz + im * 2π * frequency * Jd
        adjoint = _solve_linear(
            system', selector,
            "noise adjoint matrix is singular at $(frequency) Hz"
        )
        transfers = ComplexF64[
            dot(adjoint, source.injection) +
                _noise_output_direct(cc, output_observable, source) for source in sources
        ]
        densities = Float64[
            _noise_source_psd(source, frequency, point, 0.0)
                for source in sources
        ]
        total = 0.0
        for index in eachindex(sources)
            sources[index].id in grouped_ids&&continue
            value = abs2(transfers[index]) * densities[index]
            source_output[index][frequency_index] += value
            total += value
        end
        for group in groups
            indices = [source_index[id] for id in group.source_ids]
            correlation = ComplexF64.(group.correlation(frequency, point, 0.0))
            _validate_correlation(correlation, group.id)
            scales = sqrt.(densities[indices])
            covariance = Diagonal(scales) * correlation * Diagonal(scales)
            group_transfers = transfers[indices]
            value = real(
                dot(
                    conj.(group_transfers),
                    covariance * conj.(group_transfers)
                )
            )
            tolerance = eps(Float64) * max(sum(abs, covariance) * sum(abs2, group_transfers), 1.0)
            if value < -tolerance
                throw(AnalysisValidationError("noise group $(group.id) produced a negative output PSD"))
            elseif value < 0
                value = 0.0; corrections += 1
            end
            allocations = real.(group_transfers .* (covariance * conj.(group_transfers)))
            for (local_index, index) in enumerate(indices)
                source_output[index][frequency_index] += allocations[local_index]
            end
            total += value
        end
        output_psd[frequency_index] = total
        if input !== nothing
            response = _solve_linear(
                system, ComplexF64.(excitation),
                "noise gain matrix is singular at $(frequency) Hz"
            )
            gains[frequency_index] = abs(dot(selector, response))
        end
    end
    warnings = String[]
    input_psd = nothing
    if input !== nothing
        threshold = sqrt(eps(Float64)) * max(maximum(gains), 1.0)
        nulls = gains .<= threshold
        any(nulls)&&push!(
            warnings,
            "input-referred noise is infinite at one or more transfer nulls"
        )
        input_psd = similar(output_psd)
        for index in eachindex(output_psd)
            input_psd[index] = nulls[index] ? Inf : output_psd[index] / gains[index]^2
        end
    end
    contribution_values = NoiseSourceContribution[]
    if contributions
        for (index, source) in enumerate(sources)
            referred = input_psd === nothing ? nothing :
                [
                    isfinite(input_psd[j]) ? source_output[index][j] / gains[j]^2 : Inf
                    for j in eachindex(frequencies)
                ]
            push!(
                contribution_values, NoiseSourceContribution(
                    source.id, source.owner,
                    source.mechanism, source_output[index], referred
                )
            )
        end
    end
    stats = _finalize_stats!(
        Dict{Symbol, Any}(
            :converged => true, :temperature => Float64(temperature), :points => length(frequencies),
            :source_count => length(sources), :correlation_group_count => length(groups),
            :roundoff_psd_corrections => corrections, :bias_source => bias === nothing ? :operating_point : :provided,
            :warnings => warnings
        )
    )
    return NoiseResult(
        frequencies, output_observable, input === nothing ? nothing : Symbol(input),
        output_psd, input_psd, contribution_values, cc, stats
    )
end

function noise_figure(result::NoiseResult; source_resistance)
    result.input_referred_psd === nothing&&throw(
        ArgumentError(
            "noise figure requires an input-referred noise result"
        )
    )
    resistance = Float64(source_resistance)
    resistance > 0&&isfinite(resistance)||throw(
        ArgumentError(
            "source resistance must be finite and positive"
        )
    )
    located = _hierarchical_device(result.compiled, result.input_source)
    located !== nothing&&_batch_kind(first(located)) === :voltage_source||
        throw(ArgumentError("noise figure with source_resistance requires a voltage input source"))
    temperature = Float64(result.stats[:temperature])
    source_psd = 4 * _BOLTZMANN * temperature * resistance
    return result.input_referred_psd ./ source_psd
end

provenance(result::NoiseResult) = Dict(
    :amber_version => v"0.1.0",
    :topology_fingerprint => result.compiled.fingerprint,
    :analysis => "Noise",
    :statistics => copy(result.stats),
    :unit_system => :SI,
    :warnings => copy(result.stats[:warnings]),
)

report(result::NoiseResult) = EngineeringReport(
    Dict(
        :analysis => "Noise",
        :statistics => copy(result.stats),
        :source_count => result.stats[:source_count],
        :samples => length(result.frequencies),
        :interval => (first(result.frequencies) => last(result.frequencies)),
        :axis_unit => "Hz",
        :warnings => validity_report(result)[:warnings],
    )
)

function _noise_validity_warnings(compiled, initial = String[])
    warnings = copy(initial)
    for batch in compiled.parameters.batches
        _batch_kind(batch) in (:nmos, :pmos)||continue
        for device in eachindex(batch.parameters)
            instance_name, device_name = _locator_device_name(compiled.design, batch.locators[device])
            name = isempty(instance_name) ? device_name : string(instance_name, '.', device_name)
            push!(warnings, "$(name): " * _mos_noise_warning(batch.parameters[device].model))
        end
    end
    return warnings
end

function validity_report(result::NoiseResult)
    warnings = _noise_validity_warnings(result.compiled, result.stats[:warnings])
    return Dict(:devices => Dict{Symbol, Any}(), :warnings => warnings)
end

_mos_noise_warning(::Level1MOSFET) = "Level1MOSFET noise excludes body-diode, junction, substrate, and foundry BSIM mechanisms"
_mos_noise_warning(::ChargeBasedMOSFET) = "ChargeBasedMOSFET uses long-channel charge-based thermal noise and empirical flicker/gate noise; junction shot noise, substrate and foundry-calibrated mechanisms are excluded"
