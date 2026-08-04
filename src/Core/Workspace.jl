"""Reusable numerical storage owned by one simulation task."""
mutable struct SimulationWorkspace{T}
    state::Vector{T}
    history::Vector{T}
    derivative::Vector{T}
    residual::Vector{T}
    candidate_residual::Vector{T}
    jacobian::SparseMatrixCSC{T,Int}
    scaled_jacobian::SparseMatrixCSC{T,Int}
    system::SparseMatrixCSC{T,Int}
    rhs::Vector{T}
    update::Vector{T}
    candidate::Vector{T}
    variable_scales::Vector{T}
    row_norms::Vector{T}
    inverse_row_norms::Vector{T}
    factorization::Any
    factorization_key::Any
    numeric_factorizations::Int
end

function SimulationWorkspace(compiled::AbstractCompiledCircuit; scalar_type::Type{T}=Float64) where {T}
    n = compiled.n
    pattern = if compiled.hierarchical_topology === nothing
        compiled.jacobian_pattern
    else
        SparseMatrixCSC{Float64,Int}(compiled.hierarchical_topology.pattern)
    end
    jacobian = SparseMatrixCSC{T,Int}(pattern.m, pattern.n, copy(pattern.colptr), copy(pattern.rowval), zeros(T, length(pattern.nzval)))
    scaled_jacobian = copy(jacobian); system = copy(jacobian)
    variable_scales = ones(T, n)
    if compiled.hierarchical_topology === nothing
        for index in values(compiled.branches); variable_scales[index] = convert(T, 1e-3) end
    else
        for (index, kind) in enumerate(compiled.hierarchical_topology.layout.kinds)
            kind === BranchCurrentUnknown && (variable_scales[index] = convert(T, 1e-3))
        end
    end
    SimulationWorkspace(zeros(T, n), zeros(T, n), zeros(T, n), zeros(T, n), zeros(T, n), jacobian,
        scaled_jacobian, system, zeros(T, n), zeros(T, n), zeros(T, n), variable_scales,
        zeros(T, n), zeros(T, n), nothing, nothing, 0)
end

@inline _workspace_value(values, index::Int32) = index == 0 ? zero(eltype(values)) : values[Int(index)]
@inline function _workspace_add!(values, index::Int32, value)
    index == 0 || (values[Int(index)] += value)
    nothing
end
@inline function _workspace_stamp!(values, slot::Int32, value)
    slot == 0 || (values[Int(slot)] += value)
    nothing
end

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
    nothing
end

function _stamp_two_terminal!(residual, nzval, batch, device, current, conductance)
    p = batch.terminals[1][device]; n = batch.terminals[2][device]
    _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
    _workspace_stamp!(nzval, batch.jacobian_slots[1, device], conductance)
    _workspace_stamp!(nzval, batch.jacobian_slots[2, device], -conductance)
    _workspace_stamp!(nzval, batch.jacobian_slots[3, device], -conductance)
    _workspace_stamp!(nzval, batch.jacobian_slots[4, device], conductance)
    nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:conductance}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]
        conductance = batch.parameters[device].value
        current = conductance * (_workspace_value(state, p) - _workspace_value(state, n))
        _stamp_two_terminal!(residual, nzval, batch, device, current, conductance)
    end
    nothing
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
    nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:current_source}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]
        current = source_scale * _source_value(batch.parameters[device], t, mode)
        _workspace_add!(residual, p, current); _workspace_add!(residual, n, -current)
    end
    nothing
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
    nothing
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
    nothing
end

@inline function _workspace_matrix_stamp!(nzval, batch, device, width, row, column, value)
    ordinal = (row - 1) * width + column
    _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], value)
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
    nothing
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
        for ordinal in 1:6; _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal]) end
    end
    nothing
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
    nothing
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
        for ordinal in 1:5; _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal]) end
    end
    nothing
end

function _assemble_batch!(workspace, batch::PrimitiveBatch{Val{:diode}}, state, derivative, t, α, mode, source_scale, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        p = batch.terminals[1][device]; n = batch.terminals[2][device]; model = batch.parameters[device].model
        voltage = _workspace_value(state, p) - _workspace_value(state, n)
        current, conductance = _diode_conduction(model, voltage, temperature)
        capacitance = differential_capacitance(model, voltage; temperature)
        current += capacitance * (_workspace_value(derivative, p) - _workspace_value(derivative, n))
        _stamp_two_terminal!(residual, nzval, batch, device, current, conductance + α * capacitance)
    end
    nothing
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
    nothing
end

function _assemble_mosfet_batch!(workspace, batch, kind::Symbol, state, derivative, α, temperature)
    residual = workspace.residual; nzval = workspace.jacobian.nzval
    @inbounds for device in eachindex(batch.parameters)
        q = ntuple(index -> batch.terminals[index][device], 4); model = batch.parameters[device].model
        vd, vg, vs, vb = (_workspace_value(state, q[index]) for index in 1:4)
        channel, derivatives = _mosfet_channel(model, kind, vd, vg, vs, vb)
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
    nothing
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
        values = (conductance, -conductance, control_derivative, -control_derivative,
            -conductance, conductance, -control_derivative, control_derivative)
        for ordinal in 1:8; _workspace_stamp!(nzval, batch.jacobian_slots[ordinal, device], values[ordinal]) end
    end
    nothing
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
    nothing
end

_inplace_batch_supported(::ResistorBatch) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:resistor}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:conductance}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:capacitor}}) = true
_inplace_batch_supported(::PrimitiveBatch{Val{:current_source}}) = true
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
_linear_batch(::PrimitiveBatch{Val{:resistor}}) = true
_linear_batch(::PrimitiveBatch{Val{:conductance}}) = true
_linear_batch(::PrimitiveBatch{Val{:capacitor}}) = true
_linear_batch(::PrimitiveBatch{Val{:current_source}}) = true
_linear_batch(::PrimitiveBatch{Val{:voltage_source}}) = true
_linear_batch(::PrimitiveBatch{Val{:inductor}}) = true
_linear_batch(::PrimitiveBatch{Val{:vccs}}) = true
_linear_batch(::PrimitiveBatch{Val{:vcvs}}) = true
_linear_batch(::PrimitiveBatch{Val{:cccs}}) = true
_linear_batch(::PrimitiveBatch{Val{:ccvs}}) = true
_linear_batch(::AbstractCompiledBatch) = false

_all_inplace_supported(::Tuple{}) = true
_all_inplace_supported(batches::Tuple) =
    _inplace_batch_supported(first(batches)) && _all_inplace_supported(Base.tail(batches))
_all_linear(::Tuple{}) = true
_all_linear(batches::Tuple) = _linear_batch(first(batches)) && _all_linear(Base.tail(batches))

_assemble_batches!(workspace, ::Tuple{}, state, derivative, t, α, mode, source_scale, temperature) = nothing
function _assemble_batches!(workspace, batches::Tuple, state, derivative, t, α, mode, source_scale, temperature)
    _assemble_batch!(workspace, first(batches), state, derivative, t, α, mode, source_scale, temperature)
    _assemble_batches!(workspace, Base.tail(batches), state, derivative, t, α, mode, source_scale, temperature)
end

"""Assemble residual and Jacobian in reusable storage for a compiled hierarchy."""
function residual_jacobian!(workspace::SimulationWorkspace, compiled::CompiledCircuit, state, previous, t, α;
        mode=:time, source_scale=1.0, gmin=0.0, temperature=300.0)
    compiled.parameters === nothing && throw(ArgumentError("in-place batch assembly requires a compiled CircuitDesign"))
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
    workspace.residual, workspace.jacobian
end

function residual!(workspace::SimulationWorkspace, compiled::CompiledCircuit, state, derivative, t;
        mode=:time, source_scale=1.0, gmin=0.0, temperature=300.0)
    compiled.parameters === nothing && throw(ArgumentError("in-place batch assembly requires a compiled CircuitDesign"))
    _all_inplace_supported(compiled.parameters.batches) ||
        throw(ArgumentError("one or more compiled batches do not support in-place assembly"))
    fill!(workspace.residual, zero(eltype(workspace.residual)))
    fill!(workspace.jacobian.nzval, zero(eltype(workspace.jacobian.nzval)))
    if gmin != 0
        @inbounds for index in 1:compiled.hierarchical_topology.hierarchy.solver_net_count
            workspace.residual[index] += gmin * state[index]
        end
    end
    _assemble_batches!(workspace, compiled.parameters.batches, state, derivative, t, zero(eltype(state)), mode, source_scale, temperature)
    workspace.residual
end

jacobian!(workspace::SimulationWorkspace, compiled::CompiledCircuit, state, previous, t, α; kwargs...) =
    last(residual_jacobian!(workspace, compiled, state, previous, t, α; kwargs...))
