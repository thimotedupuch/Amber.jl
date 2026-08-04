"""Reusable numerical storage owned by one simulation task."""
mutable struct SimulationWorkspace{T}
    state::Vector{T}
    history::Vector{T}
    derivative::Vector{T}
    residual::Vector{T}
    candidate_residual::Vector{T}
    jacobian::SparseMatrixCSC{T,Int}
    rhs::Vector{T}
    update::Vector{T}
end

function SimulationWorkspace(compiled::CompiledCircuit; scalar_type::Type{T}=Float64) where {T}
    n = compiled.n
    pattern = if compiled.hierarchical_topology === nothing
        compiled.jacobian_pattern
    else
        SparseMatrixCSC{Float64,Int}(compiled.hierarchical_topology.pattern)
    end
    jacobian = SparseMatrixCSC{T,Int}(pattern.m, pattern.n, copy(pattern.colptr), copy(pattern.rowval), zeros(T, length(pattern.nzval)))
    SimulationWorkspace(zeros(T, n), zeros(T, n), zeros(T, n), zeros(T, n), zeros(T, n), jacobian, zeros(T, n), zeros(T, n))
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

_inplace_linear_batch(::ResistorBatch) = true
_inplace_linear_batch(::PrimitiveBatch{Val{:resistor}}) = true
_inplace_linear_batch(::PrimitiveBatch{Val{:conductance}}) = true
_inplace_linear_batch(::PrimitiveBatch{Val{:capacitor}}) = true
_inplace_linear_batch(::PrimitiveBatch{Val{:current_source}}) = true
_inplace_linear_batch(::PrimitiveBatch{Val{:voltage_source}}) = true
_inplace_linear_batch(::PrimitiveBatch{Val{:inductor}}) = true
_inplace_linear_batch(::AbstractCompiledBatch) = false

_all_inplace_linear(::Tuple{}) = true
_all_inplace_linear(batches::Tuple) = _inplace_linear_batch(first(batches)) && _all_inplace_linear(Base.tail(batches))

_assemble_batches!(workspace, ::Tuple{}, state, derivative, t, α, mode, source_scale, temperature) = nothing
function _assemble_batches!(workspace, batches::Tuple, state, derivative, t, α, mode, source_scale, temperature)
    _assemble_batch!(workspace, first(batches), state, derivative, t, α, mode, source_scale, temperature)
    _assemble_batches!(workspace, Base.tail(batches), state, derivative, t, α, mode, source_scale, temperature)
end

"""Assemble residual and Jacobian in reusable storage for a compiled linear hierarchy."""
function residual_jacobian!(workspace::SimulationWorkspace, compiled::CompiledCircuit, state, previous, t, α;
        mode=:time, source_scale=1.0, gmin=0.0, temperature=300.0)
    compiled.parameters === nothing && throw(ArgumentError("in-place batch assembly requires a compiled CircuitDesign"))
    _all_inplace_linear(compiled.parameters.batches) || throw(ArgumentError("in-place assembly for nonlinear batches is introduced in the next solver increment"))
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
    _all_inplace_linear(compiled.parameters.batches) || throw(ArgumentError("in-place assembly for nonlinear batches is introduced in the next solver increment"))
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
