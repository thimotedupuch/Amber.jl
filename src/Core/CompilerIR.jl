"""A hierarchy-qualified primitive reference without a materialized path string."""
struct DeviceLocator
    instance::InstanceId
    template::TemplateId
    primitive::Int32
    path::PathId
end

"""The compact mapping from retained hierarchy to global solver identities."""
struct ElaborationIndex
    root_net_to_solver::Vector{Int32}
    instance_internal_base::Vector{Int32}
    instance_to_path::Vector{PathId}
    primitive_count::Int
    solver_net_count::Int
    unknown_count::Int
end

struct SparsePattern
    colptr::Vector{Int}
    rowval::Vector{Int}
    diagonal_slots::Vector{Int}
    n::Int
end

@enum UnknownKind::UInt8 begin
    NodeVoltageUnknown
    BranchCurrentUnknown
    DeviceStateUnknown
    PartitionInterfaceUnknown
end

@enum EquationKind::UInt8 begin
    KCLCurrentEquation
    VoltageConstraintEquation
    DynamicStateEquation
    DeviceAuxiliaryEquation
end

"""Typed classification and ownership metadata for every solver unknown."""
struct UnknownLayout
    kinds::Vector{UnknownKind}
    locators::Vector{Union{Nothing,DeviceLocator}}
    state_names::Vector{Union{Nothing,Symbol}}
end

"""Typed classification and ownership metadata for every circuit equation."""
struct EquationLayout
    kinds::Vector{EquationKind}
    locators::Vector{Union{Nothing,DeviceLocator}}
end

SparseArrays.SparseMatrixCSC{Float64,Int}(pattern::SparsePattern) =
    SparseMatrixCSC(pattern.n, pattern.n, copy(pattern.colptr), copy(pattern.rowval), zeros(Float64, length(pattern.rowval)))

abstract type AbstractCompiledBatch end

"""Typed structure-of-arrays batch used by all non-resistor kernels."""
struct PrimitiveBatch{K,N,P} <: AbstractCompiledBatch
    terminals::NTuple{N,Vector{Int32}}
    parameters::Vector{P}
    residual_slots::Matrix{Int32}
    jacobian_slots::Matrix{Int32}
    branch_unknowns::Vector{Int32}
    control_unknowns::Vector{Int32}
    state_unknowns::Vector{Vector{Int32}}
    locators::Vector{DeviceLocator}
end

"""Hot-path resistor batch with conductance evaluated during compilation."""
struct ResistorBatch{T,P} <: AbstractCompiledBatch
    p::Vector{Int32}
    n::Vector{Int32}
    conductance::Vector{T}
    parameters::Vector{P}
    residual_slots::Matrix{Int32}
    jacobian_slots::Matrix{Int32}
    locators::Vector{DeviceLocator}
end

_batch_kind(::ResistorBatch) = :resistor
_batch_kind(::PrimitiveBatch{Val{K}}) where {K} = K

struct ParameterStore{B<:Tuple}
    batches::B
    fingerprint::UInt128
end

struct HierarchicalCompiledTopology
    layout::UnknownLayout
    equations::EquationLayout
    hierarchy::ElaborationIndex
    pattern::SparsePattern
    batch_kinds::Tuple
    topology_fingerprint::UInt128
end

struct TopologyParameterError <: Exception
    path::String
    parameter::Symbol
end
function Base.showerror(io::IO, error::TopologyParameterError)
    print(io, "$(error.path).$(error.parameter) is structural; rebuild the affected template or design instead of applying a numerical override")
end

mutable struct _BatchBuilder
    kind::Symbol
    parameter_type::DataType
    terminals::Vector{Vector{Int32}}
    parameters::Vector{Any}
    residual_slots::Matrix{Int32}
    jacobian_slots::Matrix{Int32}
    branch_unknowns::Vector{Int32}
    control_unknowns::Vector{Int32}
    state_unknowns::Vector{Vector{Int32}}
    locators::Vector{DeviceLocator}
end

struct _Contribution
    column::Int32
    row::Int32
    batch::Int32
    device::Int32
    ordinal::UInt8
end

struct _InstanceParameterValues
    specifications::Vector{ParameterSpec}
    data::Vector{Any}
    start::Int
end
function Base.getindex(values::_InstanceParameterValues, name::NameId)
    for (offset, specification) in enumerate(values.specifications)
        specification.name == name && return values.data[values.start + offset - 1]
    end
    throw(KeyError(name))
end
struct _EmptyParameterValues end
Base.getindex(::_EmptyParameterValues, name::NameId) = throw(KeyError(name))

function _solver_root_nets(design::CircuitDesign)
    mapping = zeros(Int32, length(design.root_ir.net_names))
    next = Int32(0)
    for local_id in eachindex(mapping)
        local_id == design.root_ir.ground_net && continue
        next += Int32(1); mapping[local_id] = next
    end
    mapping, next
end

function _instance_internal_bases(design::CircuitDesign, root_solver_count::Int32)
    bases = zeros(Int32, length(design.root.records))
    next = root_solver_count
    for (index, record) in enumerate(design.root.records)
        template = design.templates.templates[Int(record.template)]
        internal_count = length(template.body.net_names) - length(template.ports)
        bases[index] = next + 1
        next += Int32(internal_count)
    end
    bases, next
end

@inline function _instance_solver_net(design::CircuitDesign, root_mapping, internal_bases,
        instance_index::Int, record::InstanceRecord, local_net::Int32)
    template = design.templates.templates[Int(record.template)]
    port_count = length(template.ports)
    if local_net <= port_count
        connection_index = Int(record.connections.start) + Int(local_net) - 1
        return root_mapping[Int(design.root.connection_data[connection_index])]
    end
    internal_bases[instance_index] + local_net - Int32(port_count) - 1
end

function _foreach_hierarchical_primitive(f::F, design::CircuitDesign, root_mapping, internal_bases; materialize::Bool=true) where {F}
    for (primitive_index, primitive) in enumerate(design.root_ir.primitives)
        terminals = ntuple(i -> root_mapping[Int(design.root_ir.terminal_data[first(primitive.terminals) + i - 1])], length(primitive.terminals))
        parameters = materialize ? _materialize_parameter(primitive.parameters, _EmptyParameterValues(), nothing) : nothing
        f(primitive, terminals, parameters, DeviceLocator(InstanceId(0), TemplateId(0), Int32(primitive_index), PathId(0)))
    end
    for (instance_index, record) in enumerate(design.root.records)
        template = design.templates.templates[Int(record.template)]
        parameter_values = _InstanceParameterValues(template.parameters, design.root.parameter_data, Int(record.parameters.start))
        for (primitive_index, primitive) in enumerate(template.body.primitives)
            terminals = ntuple(i -> _instance_solver_net(design, root_mapping, internal_bases, instance_index, record,
                template.body.terminal_data[first(primitive.terminals) + i - 1]), length(primitive.terminals))
            parameters = materialize ? _materialize_parameter(primitive.parameters, parameter_values, nothing) : nothing
            f(primitive, terminals, parameters, DeviceLocator(InstanceId(instance_index), record.template, Int32(primitive_index), record.path))
        end
    end
    nothing
end

function _stamp_shape(kind::Symbol, contract::DeviceContract)
    if kind in (:resistor, :conductance, :capacitor, :diode)
        return 4
    elseif kind in (:voltage_source, :inductor)
        return 5
    elseif kind === :vccs
        return 4
    elseif kind === :current_source
        return 0
    elseif kind === :vcvs
        return 6
    elseif kind === :cccs
        return 2
    elseif kind === :ccvs
        return 5
    elseif kind in (:npn, :nmos, :pmos)
        return contract.terminals^2
    elseif kind === :switch
        return 8
    elseif kind === :opamp
        return 9
    end
    throw(ArgumentError("unsupported device kind $(kind)"))
end

function _emit_stamp_positions!(emit, kind::Symbol, q, branch::Int32, states, control::Int32)
    if kind in (:resistor, :conductance, :capacitor, :diode)
        for row in q[1:2], column in q[1:2]; emit(row, column) end
    elseif kind in (:voltage_source, :inductor)
        for node in q[1:2]; emit(node, branch); emit(branch, node) end
        emit(branch, branch)
    elseif kind === :vccs
        for row in q[3:4], column in q[1:2]; emit(row, column) end
    elseif kind === :vcvs
        for node in q[3:4]; emit(node, branch); emit(branch, node) end
        for column in q[1:2]; emit(branch, column) end
    elseif kind === :cccs
        emit(q[1], control); emit(q[2], control)
    elseif kind === :ccvs
        for node in q[1:2]; emit(node, branch); emit(branch, node) end
        emit(branch, control)
    elseif kind in (:npn, :nmos, :pmos)
        for row in q, column in q; emit(row, column) end
    elseif kind === :switch
        for row in q[1:2], column in q; emit(row, column) end
    elseif kind === :opamp
        state = first(states)
        emit(q[3], branch); emit(branch, q[3]); emit(branch, branch); emit(branch, state)
        emit(branch, q[4]); emit(branch, q[5]); emit(state, state); emit(state, q[1]); emit(state, q[2])
    end
end

function _batch_key(kind::Symbol, parameters)
    (kind, typeof(parameters))
end

function _new_batch_builder(kind, parameter_type, terminal_count, stamp_count)
    _BatchBuilder(kind, parameter_type, [Int32[] for _ in 1:terminal_count], Any[],
        Matrix{Int32}(undef, terminal_count, 0), Matrix{Int32}(undef, stamp_count, 0),
        Int32[], Int32[], Vector{Int32}[], DeviceLocator[])
end

function _pattern_from_contributions!(contributions::Vector{_Contribution}, builders, unknown_count::Int, diagonal_count::Int)
    for diagonal in 1:diagonal_count
        push!(contributions, _Contribution(Int32(diagonal), Int32(diagonal), 0, 0, 0))
    end
    sort!(contributions; by=contribution -> (contribution.column, contribution.row, contribution.batch, contribution.device, contribution.ordinal))
    colptr = ones(Int, unknown_count + 1); rowval = Int[]; diagonal_slots = zeros(Int, unknown_count)
    previous_column = 0; previous_row = 0; slot = 0
    for contribution in contributions
        column = Int(contribution.column); row = Int(contribution.row)
        (column == 0 || row == 0) && continue
        if column != previous_column || row != previous_row
            while previous_column < column
                colptr[previous_column + 1] = slot + 1
                previous_column += 1
            end
            push!(rowval, row); slot += 1; previous_row = row
            row == column && (diagonal_slots[row] = slot)
        end
        if contribution.batch != 0
            builder = builders[Int(contribution.batch)]
            builder.jacobian_slots[Int(contribution.ordinal), Int(contribution.device)] = Int32(slot)
        end
    end
    while previous_column < unknown_count
        colptr[previous_column + 1] = slot + 1; previous_column += 1
    end
    colptr[end] = slot + 1
    SparsePattern(colptr, rowval, diagonal_slots, unknown_count)
end

function _freeze_batch(builder::_BatchBuilder)
    terminal_tuple = Tuple(builder.terminals)
    parameters = convert(Vector{builder.parameter_type}, builder.parameters)
    if builder.kind === :resistor
        conductance = Float64[inv(Float64(parameter.value)) for parameter in parameters]
        return ResistorBatch(terminal_tuple[1], terminal_tuple[2], conductance, parameters, builder.residual_slots,
            builder.jacobian_slots, builder.locators)
    end
    PrimitiveBatch{Val{builder.kind},length(terminal_tuple),builder.parameter_type}(terminal_tuple, parameters,
        builder.residual_slots, builder.jacobian_slots, builder.branch_unknowns, builder.control_unknowns,
        builder.state_unknowns, builder.locators)
end

function _compile_hierarchy(design::CircuitDesign)
    root_mapping, root_solver_count = _solver_root_nets(design)
    internal_bases, solver_net_count = _instance_internal_bases(design, root_solver_count)
    primitive_count = length(design.root_ir.primitives) + sum(record -> length(design.templates.templates[Int(record.template)].body.primitives), design.root.records; init=0)

    batch_keys = Tuple{Symbol,DataType}[]; batch_lookup = Dict{Tuple{Symbol,DataType},Int}(); counts = Int[]
    branch_count = 0; state_count = 0; cached_parameters = Any[]
    sizehint!(cached_parameters, primitive_count)
    _foreach_hierarchical_primitive(design, root_mapping, internal_bases) do primitive, terminals, parameters, locator
        kind = typeof(primitive.kernel).parameters[1]; contract = device_contract(kind)
        key = _batch_key(kind, parameters)
        batch = get!(batch_lookup, key) do
            push!(batch_keys, key); push!(counts, 0); length(batch_keys)
        end
        counts[batch] += 1
        push!(cached_parameters, parameters)
        branch_count += contract.branch
        state_count += length(contract.states)
    end
    unknown_count = Int(solver_net_count) + branch_count + state_count
    branch_by_primitive = zeros(Int32, primitive_count)
    states_by_primitive = Vector{Vector{Int32}}(undef, primitive_count)
    branch_lookup = Dict{Tuple{UInt32,UInt32,Int32},Int32}()
    next_unknown = Int32(solver_net_count); primitive_ordinal = 0
    _foreach_hierarchical_primitive(design, root_mapping, internal_bases; materialize=false) do primitive, terminals, parameters, locator
        primitive_ordinal += 1; contract = device_contract(typeof(primitive.kernel).parameters[1])
        if contract.branch
            next_unknown += Int32(1); branch_by_primitive[primitive_ordinal] = next_unknown
            branch_lookup[(locator.instance.value, locator.template.value, locator.primitive)] = next_unknown
        end
        states = Int32[]
        for _ in contract.states; next_unknown += Int32(1); push!(states, next_unknown) end
        states_by_primitive[primitive_ordinal] = states
    end
    builders = [_new_batch_builder(kind, parameter_type, device_contract(kind).terminals,
        _stamp_shape(kind, device_contract(kind))) for ((kind, parameter_type), count) in zip(batch_keys, counts)]
    for (builder, count) in zip(builders, counts)
        foreach(column -> sizehint!(column, count), builder.terminals)
        sizehint!(builder.parameters, count); sizehint!(builder.branch_unknowns, count); sizehint!(builder.control_unknowns, count)
        sizehint!(builder.state_unknowns, count); sizehint!(builder.locators, count)
        builder.residual_slots = zeros(Int32, length(builder.terminals), count)
        builder.jacobian_slots = zeros(Int32, size(builder.jacobian_slots, 1), count)
    end

    contributions = _Contribution[]; sizehint!(contributions, 10 * primitive_count + unknown_count)
    batch_positions = zeros(Int, length(builders))
    primitive_ordinal = 0
    _foreach_hierarchical_primitive(design, root_mapping, internal_bases; materialize=false) do primitive, terminals, ignored_parameters, locator
        primitive_ordinal += 1
        parameters = cached_parameters[primitive_ordinal]
        kind = typeof(primitive.kernel).parameters[1]; contract = device_contract(kind)
        batch_index = batch_lookup[_batch_key(kind, parameters)]
        batch_positions[batch_index] += 1; device_index = batch_positions[batch_index]
        builder = builders[batch_index]
        for (column, terminal) in zip(builder.terminals, terminals); push!(column, terminal) end
        push!(builder.parameters, parameters); push!(builder.locators, locator)
        for (terminal_index, terminal) in enumerate(terminals)
            builder.residual_slots[terminal_index, device_index] = terminal
        end
        branch = branch_by_primitive[primitive_ordinal]
        push!(builder.branch_unknowns, branch)
        states = states_by_primitive[primitive_ordinal]
        push!(builder.state_unknowns, states)
        control = Int32(0)
        if kind in (:cccs, :ccvs)
            reference = parameters.control
            if reference isa LocalPrimitiveReference
                control = get(branch_lookup, (locator.instance.value, locator.template.value, reference.id), Int32(0))
            elseif reference isa Symbol
                body = locator.instance.value == 0 ? design.root_ir : design.templates.templates[Int(locator.template)].body
                names = locator.instance.value == 0 ? design.names : design.templates.templates[Int(locator.template)].names
                referenced = findfirst(candidate -> _name(names, candidate.name) == String(reference), body.primitives)
                referenced === nothing || (control = get(branch_lookup, (locator.instance.value, locator.template.value, Int32(referenced)), Int32(0)))
            end
            control == 0 && throw(ArgumentError("controlled source refers to a primitive without a branch-current unknown"))
        end
        push!(builder.control_unknowns, control)
        local_contribution = 0
        _emit_stamp_positions!(kind, terminals, branch, states, control) do row, column
            local_contribution += 1
            (row == 0 || column == 0) && return
            push!(contributions, _Contribution(Int32(column), Int32(row), Int32(batch_index), Int32(device_index), UInt8(local_contribution)))
        end
    end
    pattern = _pattern_from_contributions!(contributions, builders, unknown_count, Int(solver_net_count))
    batches = Tuple(_freeze_batch(builder) for builder in builders)
    hierarchy = ElaborationIndex(root_mapping, internal_bases, getfield.(design.root.records, :path),
        primitive_count, Int(solver_net_count), unknown_count)
    unknown_kinds = fill(NodeVoltageUnknown, unknown_count)
    equation_kinds = fill(KCLCurrentEquation, unknown_count)
    unknown_locators = Union{Nothing,DeviceLocator}[nothing for _ in 1:unknown_count]
    equation_locators = Union{Nothing,DeviceLocator}[nothing for _ in 1:unknown_count]
    state_names = Union{Nothing,Symbol}[nothing for _ in 1:unknown_count]
    for batch in batches
        batch isa PrimitiveBatch || continue
        for (device, branch) in enumerate(batch.branch_unknowns)
            branch == 0 && continue
            unknown_kinds[Int(branch)] = BranchCurrentUnknown
            equation_kinds[Int(branch)] = VoltageConstraintEquation
            unknown_locators[Int(branch)] = batch.locators[device]
            equation_locators[Int(branch)] = batch.locators[device]
        end
        for (device, states) in enumerate(batch.state_unknowns), (state_index, unknown) in enumerate(states)
            unknown_kinds[Int(unknown)] = DeviceStateUnknown
            equation_kinds[Int(unknown)] = DynamicStateEquation
            unknown_locators[Int(unknown)] = batch.locators[device]
            equation_locators[Int(unknown)] = batch.locators[device]
            contract = device_contract(_batch_kind(batch))
            state_names[Int(unknown)] = contract.states[state_index]
        end
    end
    batch_kinds = Tuple(first(key) for key in batch_keys)
    layout = UnknownLayout(unknown_kinds, unknown_locators, state_names)
    equations = EquationLayout(equation_kinds, equation_locators)
    topology = HierarchicalCompiledTopology(layout, equations, hierarchy, pattern, batch_kinds,
        design.structural_fingerprint)
    parameters = ParameterStore(batches, design.parameter_fingerprint)
    topology, parameters
end

const _STRUCTURAL_PARAMETER_NAMES = Set((
    :series_resistance, :winding_resistance, :parallel_capacitance,
    :leakage_resistance, :esr, :esl, :package, :dielectric_absorption,
))

function _locator_device_name(design::CircuitDesign, locator::DeviceLocator)
    if locator.instance.value == 0
        primitive = design.root_ir.primitives[Int(locator.primitive)]
        return "", _name(design.names, primitive.name)
    end
    record = design.root.records[Int(locator.instance)]
    template = design.templates.templates[Int(locator.template)]
    primitive = template.body.primitives[Int(locator.primitive)]
    string(InstancePath(_path_segments(design, record.path))), _name(template.names, primitive.name)
end

function _parse_parameter_selector(selector::AbstractString)
    text = String(selector)
    matched = match(r"^(.*)\.([^.]+)\.([A-Za-z_][A-Za-z0-9_]*)$", text)
    if matched === nothing
        root_match = match(r"^([^.]+)\.([A-Za-z_][A-Za-z0-9_]*)$", text)
        root_match === nothing && throw(ArgumentError("parameter selector must have the form device.parameter or instance.device.parameter"))
        device_name, parameter_text = root_match.captures
        return "", nothing, device_name, Symbol(parameter_text)
    end
    instance_text, device_name, parameter_text = matched.captures
    range_match = match(r"^(.*)\[(-?\d+):(-?\d+)\]$", instance_text)
    if range_match === nothing
        return instance_text, nothing, device_name, Symbol(parameter_text)
    end
    range = parse(Int, range_match.captures[2]):parse(Int, range_match.captures[3])
    range_match.captures[1], range, device_name, Symbol(parameter_text)
end

function _matches_selector(instance_path, device_name, selector_instance, selector_range, selector_device)
    device_name == selector_device || return false
    selector_range === nothing && return instance_path == selector_instance
    matched = match(r"^(.*)\[(-?\d+)\]$", instance_path)
    matched === nothing && return false
    matched.captures[1] == selector_instance && parse(Int, matched.captures[2]) in selector_range
end

function _updated_batch(batch::ResistorBatch, design, selector, value)
    selector_instance, selector_range, selector_device, parameter = selector
    parameter in _STRUCTURAL_PARAMETER_NAMES && throw(TopologyParameterError(join(filter(!isempty, (selector_instance, selector_device)), '.'), parameter))
    parameter === :value || throw(ArgumentError("resistor batches expose the numerical parameter `value`"))
    conductance = batch.conductance; parameters = batch.parameters; copied = false; matches = Int[]
    for (index, locator) in enumerate(batch.locators)
        instance_path, device_name = _locator_device_name(design, locator)
        _matches_selector(instance_path, device_name, selector_instance, selector_range, selector_device) || continue
        copied || (conductance = copy(conductance); parameters = copy(parameters); copied = true)
        conductance[index] = inv(convert(eltype(conductance), value)); push!(matches, index)
        P = eltype(parameters)
        parameters[index] = convert(P, merge(parameters[index], (value=value,)))
    end
    copied ? ResistorBatch(batch.p, batch.n, conductance, parameters, batch.residual_slots, batch.jacobian_slots, batch.locators) : batch, matches
end


function _updated_batch(batch::PrimitiveBatch{K,N,P}, design, selector, value) where {K,N,P}
    selector_instance, selector_range, selector_device, parameter = selector
    parameter in _STRUCTURAL_PARAMETER_NAMES && throw(TopologyParameterError(join(filter(!isempty, (selector_instance, selector_device)), '.'), parameter))
    values = batch.parameters; copied = false; matches = Int[]
    for (index, locator) in enumerate(batch.locators)
        instance_path, device_name = _locator_device_name(design, locator)
        _matches_selector(instance_path, device_name, selector_instance, selector_range, selector_device) || continue
        hasproperty(values[index], parameter) || throw(ArgumentError("device $(device_name) has no numerical parameter $(parameter)"))
        copied || (values = copy(values); copied = true)
        values[index] = convert(P, merge(values[index], NamedTuple{(parameter,)}((value,))))
        push!(matches, index)
    end
    copied ? PrimitiveBatch{K,N,P}(batch.terminals, values, batch.residual_slots, batch.jacobian_slots,
        batch.branch_unknowns, batch.control_unknowns, batch.state_unknowns, batch.locators) : batch, matches
end

function _parameter_store_fingerprint(batches)
    io = IOBuffer()
    for batch in batches
        if batch isa ResistorBatch
            print(io, :resistor, ':', repr(batch.conductance), ';')
        else
            print(io, _batch_kind(batch), ':', repr(batch.parameters), ';')
        end
    end
    digest = sha256(take!(io)); value = zero(UInt128)
    for byte in digest[1:16]; value = (value << 8) | UInt128(byte) end
    value
end

"""Return a compiled circuit with copy-on-write numerical batch updates.

Untouched batches and all topology arrays are shared. Structural parameters are
rejected because changing them requires hierarchy elaboration and a new pattern.
"""
function with_parameters(compiled, updates::Pair...)
    compiled.design === nothing && throw(ArgumentError("with_parameters requires a compiled CircuitDesign"))
    batches = collect(compiled.parameters.batches)
    for (selector_text, value) in updates
        selector = _parse_parameter_selector(String(selector_text))
        selector[4] in _STRUCTURAL_PARAMETER_NAMES && throw(TopologyParameterError(String(selector_text), selector[4]))
        matched = false
        for index in eachindex(batches)
            updated, matches = _updated_batch(batches[index], compiled.design, selector, value)
            batches[index] = updated; matched |= !isempty(matches)
        end
        matched || throw(KeyError(selector_text))
    end
    new_batches = Tuple(batches)
    store = ParameterStore(new_batches, _parameter_store_fingerprint(new_batches))
    fingerprint = bytes2hex(sha1(string(compiled.design.structural_fingerprint, ':', store.fingerprint)))
    CompiledCircuit(compiled.design, compiled.topology, store, fingerprint)
end

with_parameters(compiled, updates::AbstractVector{<:Pair}) = with_parameters(compiled, updates...)
