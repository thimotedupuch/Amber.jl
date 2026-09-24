"""Reusable numerical storage owned by one simulation task."""
mutable struct SimulationWorkspace{T}
    state::Vector{T}
    history::Vector{T}
    derivative::Vector{T}
    residual::Vector{T}
    candidate_residual::Vector{T}
    jacobian::SparseMatrixCSC{T, Int}
    scaled_jacobian::SparseMatrixCSC{T, Int}
    system::SparseMatrixCSC{T, Int}
    rhs::Vector{T}
    update::Vector{T}
    candidate::Vector{T}
    variable_scales::Vector{T}
    row_norms::Vector{T}
    inverse_row_norms::Vector{T}
    factorization::Any
    factorization_key::Any
    numeric_factorizations::Int
    storage::Vector{T}
    storage_jacobian::SparseMatrixCSC{T, Int}
    constant_jacobian::SparseMatrixCSC{T, Int}
    constant_storage_jacobian::SparseMatrixCSC{T, Int}
    constant_topology::Union{Nothing, HierarchicalCompiledTopology}
    constant_fingerprint::UInt128
    constant_assemblies::Int
end

function SimulationWorkspace(compiled::AbstractCompiledCircuit; scalar_type::Type{T} = Float64) where {T}
    n = compiled.n
    pattern = SparseMatrixCSC{Float64, Int}(compiled.topology.pattern)
    jacobian = SparseMatrixCSC{T, Int}(pattern.m, pattern.n, copy(pattern.colptr), copy(pattern.rowval), zeros(T, length(pattern.nzval)))
    scaled_jacobian = copy(jacobian); system = copy(jacobian)
    variable_scales = ones(T, n)
    for (index, kind) in enumerate(compiled.topology.layout.kinds)
        kind === BranchCurrentUnknown && (variable_scales[index] = convert(T, 1.0e-3))
    end
    return SimulationWorkspace(
        zeros(T, n), zeros(T, n), zeros(T, n), zeros(T, n), zeros(T, n), jacobian,
        scaled_jacobian, system, zeros(T, n), zeros(T, n), zeros(T, n), variable_scales,
        zeros(T, n), zeros(T, n), nothing, nothing, 0, zeros(T, n), copy(jacobian),
        copy(jacobian), copy(jacobian), nothing, zero(UInt128), 0
    )
end

@inline _workspace_value(values, index::Int32) = index == 0 ? zero(eltype(values)) : values[Int(index)]
@inline function _workspace_add!(values, index::Int32, value)
    index == 0 || (values[Int(index)] += value)
    return nothing
end
@inline function _workspace_stamp!(values, slot::Int32, value)
    slot == 0 || (values[Int(slot)] += value)
    return nothing
end
@inline _workspace_stamp!(::Nothing, slot::Int32, value) = nothing

# A statically selected sink lets residual-only kernels share the device laws
# without writing matrix buffers or calling user-supplied derivative functions.
_assembly_view(workspace, ::Val{J}; residual = workspace.residual) where {J} =
    (;
    residual, jacobian = (nzval = J ? workspace.jacobian.nzval : nothing,),
    storage = workspace.storage,
    storage_jacobian = (nzval = J ? workspace.storage_jacobian.nzval : nothing,),
)

function _assemble_batch!(workspace, batch::ResistorBatch, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.p)
        p = batch.p[device]; n = batch.n[device]; conductance = batch.conductance[device]
        current = conductance * (_workspace_value(state, p) - _workspace_value(state, n))
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
        _workspace_stamp!(nzval, batch.jacobian_slots[1, device], conductance)
        _workspace_stamp!(nzval, batch.jacobian_slots[2, device], -conductance)
        _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -conductance)
        _workspace_stamp!(nzval, batch.jacobian_slots[4, device], conductance)
    end
    return nothing
end

function _stamp_two_terminal!(residual, nzval, batch, device, current, conductance)
    p = batch.terminals[1][device]; n = batch.terminals[2][device]
    _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
    _workspace_stamp!(nzval, batch.jacobian_slots[1, device], conductance)
    _workspace_stamp!(nzval, batch.jacobian_slots[2, device], -conductance)
    _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -conductance)
    _workspace_stamp!(nzval, batch.jacobian_slots[4, device], conductance)
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:conductance}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]
        conductance = batch.parameters[device].value
        current = conductance * (_workspace_value(state, p) - _workspace_value(state, n))
        _stamp_two_terminal!(residual, nzval, batch, device, current, conductance)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:capacitor}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]; parameters = batch.parameters[device]
        capacitance = parameters.value
        leakage = hasproperty(parameters, :leakage_resistance) ? inv(parameters.leakage_resistance) : zero(capacitance)
        current = capacitance * (_workspace_value(derivative, p) - _workspace_value(derivative, n)) +
            leakage * (_workspace_value(state, p) - _workspace_value(state, n))
        _stamp_two_terminal!(residual, nzval, batch, device, current, α * capacitance + leakage)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:current_source}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]
        current = source_scale * _source_value(batch.parameters[device], t, mode)
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:voltage_source}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]; branch = batch.branch_unknowns[device]
        parameters = batch.parameters[device]; current = state[Int(branch)]
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
        resistance = hasproperty(parameters, :series_resistance) ? parameters.series_resistance : zero(current)
        residual[Int(branch)] += _workspace_value(state, p) - _workspace_value(state, n) -
            source_scale * _source_value(parameters, t, mode) - resistance * current
        _workspace_stamp!(nzval, batch.jacobian_slots[1, device], one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[2, device], one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[4, device], -one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[5, device], -resistance)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:inductor}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]; branch = batch.branch_unknowns[device]
        current = state[Int(branch)]; inductance = batch.parameters[device].value
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
        residual[Int(branch)] += _workspace_value(state, p) - _workspace_value(state, n) - inductance * derivative[Int(branch)]
        _workspace_stamp!(nzval, batch.jacobian_slots[1, device], one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[2, device], one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[4, device], -one(current))
        _workspace_stamp!(nzval, batch.jacobian_slots[5, device], -α * inductance)
    end
    return nothing
end

@inline function _workspace_matrix_stamp!(nzval, batch, device, width, row, column, value)
    ordinal = (row - 1) * width + column
    return _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], value)
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:vccs}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        cp, cn, op, on = (batch.terminals[index][device] for index in 1:4)
        gm = batch.parameters[device].gm
        current = gm * (_workspace_value(state, cp) - _workspace_value(state, cn))
        _workspace_add!(residual, op, current); _workspace_add!(residual, on, -current)
        _workspace_stamp!(nzval, batch.jacobian_slots[1, device], gm)
        _workspace_stamp!(nzval, batch.jacobian_slots[2, device], -gm)
        _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -gm)
        _workspace_stamp!(nzval, batch.jacobian_slots[4, device], gm)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:behavioral_current_source}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 10)
        controls = ntuple(
            index -> _workspace_value(state, q[2index + 1]) -
                _workspace_value(state, q[2index + 2]), 4
        )
        parameters = batch.parameters[device]
        current = parameters.current(controls, t)
        _workspace_add!(residual, q[1], current); _workspace_add!(residual, q[2], -current)
        nzval === nothing && continue
        gradient = parameters.gradient(controls, t)
        length(gradient) == 4 || throw(ArgumentError("behavioral current gradient must have four entries"))
        ordinal = 0
        for row_sign in (1, -1), control in 1:4, control_sign in (1, -1)
            ordinal += 1
            _workspace_stamp!(
                nzval, batch.jacobian_slots[ordinal, device],
                row_sign * control_sign * gradient[control]
            )
        end
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:behavioral_voltage_source}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 10)
        branch = batch.branch_unknowns[device]
        controls = ntuple(
            index -> _workspace_value(state, q[2index + 1]) -
                _workspace_value(state, q[2index + 2]), 4
        )
        parameters = batch.parameters[device]
        imposed_voltage = parameters.voltage(controls, t)
        current = state[Int(branch)]
        _workspace_add!(residual, q[1], current); _workspace_add!(residual, q[2], -current)
        residual[Int(branch)] += _workspace_value(state, q[1]) -
            _workspace_value(state, q[2]) - imposed_voltage
        nzval === nothing && continue
        gradient = parameters.gradient(controls, t)
        length(gradient) == 4 || throw(ArgumentError("behavioral voltage gradient must have four entries"))
        values = (
            one(current), -one(current), one(current), -one(current),
            -gradient[1], gradient[1], -gradient[2], gradient[2],
            -gradient[3], gradient[3], -gradient[4], gradient[4],
        )
        for ordinal in eachindex(values)
            _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal])
        end
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:vcvs}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        cp, cn, op, on = (batch.terminals[index][device] for index in 1:4)
        branch = batch.branch_unknowns[device]; gain = batch.parameters[device].gain; current = state[Int(branch)]
        _workspace_add!(residual, op, current); _workspace_add!(residual, on, -current)
        residual[Int(branch)] += _workspace_value(state, op) - _workspace_value(state, on) -
            gain * (_workspace_value(state, cp) - _workspace_value(state, cn))
        values = (one(current), one(current), -one(current), -one(current), -gain, gain)
        for ordinal in 1:6
            _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal])
        end
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:cccs}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]
        control = batch.control_unknowns[device]; gain = batch.parameters[device].gain
        current = gain * state[Int(control)]
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
        _workspace_stamp!(nzval, batch.jacobian_slots[1, device], gain)
        _workspace_stamp!(nzval, batch.jacobian_slots[2, device], -gain)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:ccvs}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]
        branch = batch.branch_unknowns[device]; control = batch.control_unknowns[device]
        resistance = batch.parameters[device].transresistance; current = state[Int(branch)]
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
        residual[Int(branch)] += _workspace_value(state, p) - _workspace_value(state, n) - resistance * state[Int(control)]
        values = (one(current), one(current), -one(current), -one(current), -resistance)
        for ordinal in 1:5
            _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal])
        end
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:diode}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]; model = batch.parameters[device].model
        voltage = _workspace_value(state, p) - _workspace_value(state, n)
        current, conductance = _diode_conduction(model, voltage, temperature)
        capacitance = differential_capacitance(model, voltage; temperature)
        current += capacitance * (_workspace_value(derivative, p) - _workspace_value(derivative, n))
        rate = _workspace_value(derivative, p) - _workspace_value(derivative, n)
        tangent = conductance + α * capacitance + _capacitance_slope(model, voltage; temperature) * rate
        _stamp_two_terminal!(residual, nzval, batch, device, current, tangent)
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:npn}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval; thermal_voltage = _thermal_voltage(temperature)
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 3); model = batch.parameters[device].model
        vc, vb, ve = (_workspace_value(state, q[index]) for index in 1:3)
        forward, forward_slope = _limited_exponential((vb - ve) / thermal_voltage)
        reverse, reverse_slope = _limited_exponential((vb - vc) / thermal_voltage)
        If = model.saturation_current * forward; Ir = model.saturation_current * reverse
        gf = model.saturation_current * forward_slope / thermal_voltage
        gr = model.saturation_current * reverse_slope / thermal_voltage
        αf = model.forward_beta / (model.forward_beta + 1); αr = model.reverse_beta / (model.reverse_beta + 1)
        early = 1 + (vc - ve) / model.early_voltage
        collector = αf * If * early - Ir
        base = (1 - αf) * If + (1 - αr) * Ir
        _workspace_add!(residual, q[1], collector); _workspace_add!(residual, q[2], base); _workspace_add!(residual, q[3], -collector - base)
        cbe_current = model.cbe_zero_bias * (_workspace_value(derivative, q[2]) - _workspace_value(derivative, q[3]))
        cbc_current = model.cbc_zero_bias * (_workspace_value(derivative, q[2]) - _workspace_value(derivative, q[1]))
        _workspace_add!(residual, q[2], cbe_current + cbc_current)
        _workspace_add!(residual, q[3], -cbe_current); _workspace_add!(residual, q[1], -cbc_current)
        dic = (αf * If / model.early_voltage + gr, αf * gf * early - gr, αf * (-gf * early - If / model.early_voltage))
        dib = (-(1 - αr) * gr, (1 - αf) * gf + (1 - αr) * gr, -(1 - αf) * gf)
        for column in 1:3
            _workspace_matrix_stamp!(nzval, batch, device, 3, 1, column, dic[column])
            _workspace_matrix_stamp!(nzval, batch, device, 3, 2, column, dib[column])
            _workspace_matrix_stamp!(nzval, batch, device, 3, 3, column, -dic[column] - dib[column])
        end
        cbe = α * model.cbe_zero_bias; cbc = α * model.cbc_zero_bias
        _workspace_matrix_stamp!(nzval, batch, device, 3, 2, 2, cbe + cbc)
        _workspace_matrix_stamp!(nzval, batch, device, 3, 2, 3, -cbe)
        _workspace_matrix_stamp!(nzval, batch, device, 3, 3, 2, -cbe)
        _workspace_matrix_stamp!(nzval, batch, device, 3, 3, 3, cbe)
        _workspace_matrix_stamp!(nzval, batch, device, 3, 2, 1, -cbc)
        _workspace_matrix_stamp!(nzval, batch, device, 3, 1, 2, -cbc)
        _workspace_matrix_stamp!(nzval, batch, device, 3, 1, 1, cbc)
    end
    return nothing
end

function _assemble_mosfet_batch!(workspace, batch, kind::Symbol, state, derivative, α, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 4); model = batch.parameters[device].model
        vd, vg, vs, vb = (_workspace_value(state, q[index]) for index in 1:4)
        if model isa ChargeBasedMOSFET
            evaluated = _charge_mos_evaluate(
                model, kind, (vd, vg, vs, vb); temperature,
                order = nzval === nothing ? Val(1) : Val(2)
            )
            rates = ntuple(i -> _workspace_value(derivative, q[i]), 4)
            for row in 1:4
                conductive = evaluated.currents[row]; charge = evaluated.charges[row]
                current = conductive.value + sum(charge.gradient[j] * rates[j] for j in 1:4)
                _workspace_add!(residual, q[row], current)
                nzval === nothing && continue
                for column in 1:4
                    tangent = conductive.gradient[column] + α * charge.gradient[column] +
                        sum(charge.hessian[(j - 1) * 4 + column] * rates[j] for j in 1:4)
                    _workspace_matrix_stamp!(nzval, batch, device, 4, row, column, tangent)
                end
            end
            continue
        end
        channel, derivatives = _mosfet_channel(model, kind, vd, vg, vs, vb; temperature)
        _workspace_add!(residual, q[1], channel); _workspace_add!(residual, q[3], -channel)
        capacitances = ((2, 3, model.gate_source_capacitance), (2, 1, model.gate_drain_capacitance), (2, 4, model.gate_bulk_capacitance))
        for (a, b, capacitance) in capacitances
            current = capacitance * (_workspace_value(derivative, q[a]) - _workspace_value(derivative, q[b]))
            _workspace_add!(residual, q[a], current); _workspace_add!(residual, q[b], -current)
            conductance = α * capacitance
            _workspace_matrix_stamp!(nzval, batch, device, 4, a, a, conductance)
            _workspace_matrix_stamp!(nzval, batch, device, 4, a, b, -conductance)
            _workspace_matrix_stamp!(nzval, batch, device, 4, b, a, -conductance)
            _workspace_matrix_stamp!(nzval, batch, device, 4, b, b, conductance)
        end
        for column in 1:4
            _workspace_matrix_stamp!(nzval, batch, device, 4, 1, column, derivatives[column])
            _workspace_matrix_stamp!(nzval, batch, device, 4, 3, column, -derivatives[column])
        end
    end
    return nothing
end

_assemble_batch!(workspace, batch::PrimitiveBatch{Val{:nmos}}, state, derivative, t, α, mode, source_scale, temperature) =
    _assemble_mosfet_batch!(workspace, batch, :nmos, state, derivative, α, temperature)
_assemble_batch!(workspace, batch::PrimitiveBatch{Val{:pmos}}, state, derivative, t, α, mode, source_scale, temperature) =
    _assemble_mosfet_batch!(workspace, batch, :pmos, state, derivative, α, temperature)

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:switch}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 4); model = batch.parameters[device].model
        control = _workspace_value(state, q[3]) - _workspace_value(state, q[4])
        voltage = _workspace_value(state, q[1]) - _workspace_value(state, q[2])
        conductance = _switch_conductance(model, control); current = conductance * voltage
        _workspace_add!(residual, q[1], current); _workspace_add!(residual, q[2], -current)
        control_derivative = _switch_conductance_derivative(model, control) * voltage
        values = (
            conductance, -conductance, control_derivative, -control_derivative,
            -conductance, conductance, -control_derivative, control_derivative,
        )
        for ordinal in 1:8
            _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal])
        end
    end
    return nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:opamp}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 5); model = batch.parameters[device].model
        branch = batch.branch_unknowns[device]; internal = first(batch.state_unknowns[device]); output_current = state[Int(branch)]
        target = model.dc_gain * (_workspace_value(state, q[1]) - _workspace_value(state, q[2]) + model.input_offset)
        low = _workspace_value(state, q[5]); high = _workspace_value(state, q[4]); limited = clamp(state[Int(internal)], low, high)
        pole = 2π * model.gain_bandwidth / max(model.dc_gain, 1)
        _workspace_add!(residual, q[3], output_current)
        residual[Int(branch)] += _workspace_value(state, q[3]) - limited - model.output_resistance * output_current
        residual[Int(internal)] += derivative[Int(internal)] - pole * (target - state[Int(internal)])
        _workspace_stamp!(nzval, batch.jacobian_slots[1, device], one(output_current))
        _workspace_stamp!(nzval, batch.jacobian_slots[2, device], one(output_current))
        _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -model.output_resistance)
        if state[Int(internal)] < low
            _workspace_stamp!(nzval, batch.jacobian_slots[6, device], -one(output_current))
        elseif state[Int(internal)] > high
            _workspace_stamp!(nzval, batch.jacobian_slots[5, device], -one(output_current))
        else
            _workspace_stamp!(nzval, batch.jacobian_slots[4, device], -one(output_current))
        end
        _workspace_stamp!(nzval, batch.jacobian_slots[7, device], α + pole)
        _workspace_stamp!(nzval, batch.jacobian_slots[8, device], -pole * model.dc_gain)
        _workspace_stamp!(nzval, batch.jacobian_slots[9, device], pole * model.dc_gain)
    end
    return nothing
end

_inplace_batch_supported(::ResistorBatch) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:resistor}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:conductance}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:capacitor}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:current_source}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:behavioral_current_source}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:behavioral_voltage_source}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:voltage_source}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:inductor}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:vccs}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:vcvs}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:cccs}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:ccvs}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:diode}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:npn}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:nmos}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:pmos}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:switch}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:opamp}}) = true
_inplace_batch_supported(::AbstractCompiledBatch) = false

_linear_batch(::ResistorBatch) = true
_has_storage(::ResistorBatch) = false
_has_forcing(::ResistorBatch) = false
for (kind, contract) in _DEVICE_SPECS
    @eval _linear_batch(::PrimitiveBatch{Val{$(QuoteNode(kind))}}) = $(contract.dependencies.linear)
    @eval _has_storage(::PrimitiveBatch{Val{$(QuoteNode(kind))}}) = $(contract.dependencies.storage)
    @eval _has_forcing(::PrimitiveBatch{Val{$(QuoteNode(kind))}}) = $(contract.dependencies.source)
end
_linear_batch(::AbstractCompiledBatch) = false
_has_storage(::AbstractCompiledBatch) = false
_has_forcing(::AbstractCompiledBatch) = false

_all_inplace_supported(::Tuple{}) = true
_all_inplace_supported(batches::Tuple) =
    _inplace_batch_supported(first(batches)) && _all_inplace_supported(Base.tail(batches))
_all_linear(::Tuple{}) = true
_all_linear(batches::Tuple) = _linear_batch(first(batches)) && _all_linear(Base.tail(batches))

_assemble_batches!(workspace, ::Tuple{}, state, derivative, t, α, mode, source_scale, temperature) = nothing
function _assemble_batches!(workspace, batches::Tuple, state, derivative, t, α, mode, source_scale, temperature)
    _assemble_batch!(workspace, first(batches), state, derivative, t, α, mode, source_scale, temperature)
    return _assemble_batches!(workspace, Base.tail(batches), state, derivative, t, α, mode, source_scale, temperature)
end

"""Assemble residual and Jacobian in reusable storage for a compiled hierarchy."""
function residual_jacobian!(
        workspace::SimulationWorkspace, compiled::CompiledCircuit, state, previous, t, α;
        mode = :time, source_scale = 1.0, gmin = 0.0, temperature = 300.0
    )
    _all_inplace_supported(compiled.parameters.batches) ||
        throw(ArgumentError("one or more compiled batches do not support in-place assembly"))
    length(state) == compiled.n == length(previous) || throw(DimensionMismatch("state vectors must match the compiled unknown count"))
    fill!(workspace.residual, zero(eltype(workspace.residual)))
    fill!(workspace.jacobian.nzval, zero(eltype(workspace.jacobian.nzval)))
    @inbounds @simd for index in eachindex(workspace.derivative)
        workspace.derivative[index] = α == 0 ? zero(eltype(workspace.derivative)) : α * (state[index] - previous[index])
    end
    if gmin != 0
        pattern = compiled.hierarchical_topology.pattern
        @inbounds for index in 1:compiled.hierarchical_topology.hierarchy.solver_net_count
            workspace.residual[index] += gmin * state[index]
            workspace.jacobian.nzval[pattern.diagonal_slots[index]] += gmin
        end
    end
    _assemble_batches!(workspace, compiled.parameters.batches, state, workspace.derivative, t, α, mode, source_scale, temperature)
    return workspace.residual, workspace.jacobian
end

function residual!(
        workspace::SimulationWorkspace, compiled::CompiledCircuit, state, derivative, t;
        mode = :time, source_scale = 1.0, gmin = 0.0, temperature = 300.0
    )
    _all_inplace_supported(compiled.parameters.batches) ||
        throw(ArgumentError("one or more compiled batches do not support in-place assembly"))
    length(state) == compiled.n == length(derivative) || throw(DimensionMismatch("state vectors must match the compiled unknown count"))
    fill!(workspace.residual, zero(eltype(workspace.residual)))
    if gmin != 0
        @inbounds for index in 1:compiled.hierarchical_topology.hierarchy.solver_net_count
            workspace.residual[index] += gmin * state[index]
        end
    end
    _assemble_batches!(
        _assembly_view(workspace, Val(false)), compiled.parameters.batches,
        state, derivative, t, zero(eltype(state)), mode, source_scale, temperature
    )
    return workspace.residual
end

jacobian!(workspace::SimulationWorkspace, compiled::CompiledCircuit, state, previous, t, α; kwargs...) =
    last(residual_jacobian!(workspace, compiled, state, previous, t, α; kwargs...))
