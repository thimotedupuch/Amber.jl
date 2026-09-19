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
    matrix_fingerprint::UInt128
    batch_fingerprints::Vector{UInt128}
    matrix_batch_fingerprints::Vector{UInt128}
end
function ParameterStore(batches::Tuple,fingerprint::UInt128)
    hashes=UInt128[_parameter_store_fingerprint((batch,)) for batch in batches]
    matrix_hashes=UInt128[_matrix_parameter_fingerprint((batch,)) for batch in batches]
    ParameterStore(batches,fingerprint,_combine_parameter_fingerprints(matrix_hashes),hashes,matrix_hashes)
end
function _combine_parameter_fingerprints(hashes)
    digest=sha256(join(string.(hashes),':')); value=zero(UInt128)
    for byte in digest[1:16]; value=(value<<8)|UInt128(byte) end
    value
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

struct ParameterUpdateError <: Exception
    path::String
    parameter::Symbol
    expected_type::Any
    value_type::Any
end
function Base.showerror(io::IO,error::ParameterUpdateError)
    print(io,"cannot update $(error.path).$(error.parameter) with $(error.value_type); compiled storage requires $(error.expected_type). Rebuild the design when changing parameter representation.")
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

_stamp_shape(kind::Symbol,::DeviceContract) = length(_DEVICE_STAMP_PLANS[kind].positions)

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
    :leakage_resistance, :esr, :esl, :package, :dielectric, :dielectric_absorption,
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

function _parameter_device_path(design,locator)
    instance_path,device_name=_locator_device_name(design,locator)
    isempty(instance_path) ? device_name : string(instance_path,'.',device_name)
end

function _updated_batch(batch::ResistorBatch,design,parameter,indices,value;owned=false)
    parameter === :value || throw(ArgumentError("resistor batches expose the numerical parameter `value`"))
    conductance=owned ? batch.conductance : copy(batch.conductance)
    parameters=owned ? batch.parameters : copy(batch.parameters)
    for index in indices
        P=eltype(parameters)
        converted_conductance,updated_parameters=try
            inv(convert(eltype(conductance),value)),convert(P,merge(parameters[index],(value=value,)))
        catch error
            error isa InterruptException && rethrow()
            throw(ParameterUpdateError(_parameter_device_path(design,batch.locators[index]),
                parameter,eltype(conductance),typeof(value)))
        end
        conductance[index]=converted_conductance; parameters[index]=updated_parameters
    end
    ResistorBatch(batch.p,batch.n,conductance,parameters,batch.residual_slots,batch.jacobian_slots,batch.locators)
end


# These effects are expanded into separate primitives by add!, so changing
# their stored model values cannot update the already compiled circuit.
_elaborated_model_parameters(::Type{Val{:diode}})=(:series_resistance,)
_elaborated_model_parameters(::Type{Val{:npn}})=(:base_resistance,)
_elaborated_model_parameters(::Type{Val{:switch}})=(:clock_feedthrough,)
_elaborated_model_parameters(::Type{Val{:opamp}})=(:input_capacitance,:input_bias_current)
_elaborated_model_parameters(::Type)=()

function _capacitance_has_derived_elements(parameters)
    dielectric=get(parameters,:dielectric,nothing)
    absorption=get(parameters,:dielectric_absorption,nothing)
    (dielectric isa AbstractCapacitorDielectric && dielectric.loss_tangent>0) ||
        (absorption isa DebyeBranches && any(>(0),absorption.fractions))
end

function _check_model_update(kind,old,new,path)
    _validate_model_parameters(new)
    for parameter in _elaborated_model_parameters(kind)
        getproperty(old,parameter)==getproperty(new,parameter)||
            throw(TopologyParameterError(path,parameter))
    end
end

function _updated_batch(batch::PrimitiveBatch{K,N,P},design,parameter,indices,value;owned=false) where {K,N,P}
    values=owned ? batch.parameters : copy(batch.parameters)
    for index in indices
        direct=hasproperty(values[index],parameter)
        model=hasproperty(values[index],:model) ? values[index].model : nothing
        model_values=model===nothing ? nothing : model_parameters(model)
        modeled=model_values!==nothing && hasproperty(model_values,parameter)
        path()=_parameter_device_path(design,batch.locators[index])
        (direct||modeled) || throw(ArgumentError("device $(path()) has no numerical parameter $(parameter)"))
        K===Val{:capacitor} && parameter===:value && _capacitance_has_derived_elements(values[index]) &&
            throw(TopologyParameterError(path(),parameter))
        parameter in _elaborated_model_parameters(K) && throw(TopologyParameterError(path(),parameter))
        parameter in (:control,:control_count) && throw(TopologyParameterError(path(),parameter))
        updated=direct ? merge(values[index],NamedTuple{(parameter,)}((value,))) :
            merge(values[index],(model=with_model_parameter(model,parameter,value),))
        model===nothing || _check_model_update(K,model,updated.model,path())
        try
            values[index]=convert(P,updated)
        catch error
            error isa InterruptException && rethrow()
            throw(ParameterUpdateError(path(),parameter,P,typeof(value)))
        end
    end
    PrimitiveBatch{K,N,P}(batch.terminals,values,batch.residual_slots,batch.jacobian_slots,
        batch.branch_unknowns,batch.control_unknowns,batch.state_unknowns,batch.locators)
end

# Tagged, length-delimited parameter data avoids formatting large arrays of
# model structs. The common numerical cases have a canonical byte order.
_fingerprint_value!(io,::Nothing)=write(io,UInt8('N'))
_fingerprint_value!(io,value::Float64)=(write(io,UInt8('D')); write(io,htol(reinterpret(UInt64,value))))
_fingerprint_value!(io,value::Float32)=(write(io,UInt8('F')); write(io,htol(reinterpret(UInt32,value))))
function _fingerprint_value!(io,value::Complex)
    write(io,UInt8('C')); _fingerprint_value!(io,real(value)); _fingerprint_value!(io,imag(value))
end
function _fingerprint_value!(io,value::Union{AbstractString,Symbol})
    text=String(value); write(io,value isa Symbol ? UInt8('S') : UInt8('T'))
    write(io,htol(UInt64(ncodeunits(text)))); write(io,text)
end
function _fingerprint_value!(io,value::NamedTuple)
    write(io,UInt8('K')); _fingerprint_value!(io,keys(value))
    for item in values(value); _fingerprint_value!(io,item) end
end
function _fingerprint_value!(io,value::Union{Tuple,AbstractArray})
    write(io,value isa Tuple ? UInt8('U') : UInt8('A'))
    value isa AbstractArray && _fingerprint_value!(io,size(value))
    write(io,htol(UInt64(length(value))))
    for item in value; _fingerprint_value!(io,item) end
end
function _fingerprint_value!(io,value::Union{AbstractDeviceModel,AbstractWaveform})
    write(io,UInt8('M'))
    # Built-in model type parameters repeat the complete parameter NamedTuple
    # schema, which is encoded below. Printing that type for every instance is
    # substantially more expensive than hashing its numerical data.
    T=typeof(value)
    _fingerprint_value!(io,parentmodule(T) === (@__MODULE__) ? nameof(T) : string(T))
    for name in fieldnames(typeof(value)); _fingerprint_value!(io,getfield(value,name)) end
end
function _fingerprint_value!(io,value)
    write(io,UInt8('R')); _fingerprint_value!(io,string(typeof(value)))
    _fingerprint_value!(io,repr(value))
end
function _parameter_digest(io)
    digest=sha256(take!(io)); value=zero(UInt128)
    for byte in digest[1:16]; value=(value<<8)|UInt128(byte) end
    value
end

function _parameter_store_fingerprint(batches)
    io=IOBuffer()
    for batch in batches
        _fingerprint_value!(io,_batch_kind(batch))
        _fingerprint_value!(io,batch isa ResistorBatch ? batch.conductance : batch.parameters)
    end
    _parameter_digest(io)
end

# Independent source values affect forcing, not either matrix. Keep their
# series resistance, which does enter the voltage constraint.
function _matrix_parameter_fingerprint(batches)
    io=IOBuffer()
    for batch in batches
        kind=_batch_kind(batch)
        print(io,kind,':')
        if !device_contract(kind).dependencies.linear
            # Nonlinear contributions are evaluated from current parameters on
            # every call and never enter the constant-matrix cache.
        elseif kind === :voltage_source
            for parameter in batch.parameters
                _fingerprint_value!(io,get(parameter,:series_resistance,0.))
            end
        elseif kind !== :current_source
            _fingerprint_value!(io,batch.parameters)
        end
        print(io,';')
    end
    digest=sha256(take!(io)); value=zero(UInt128)
    for byte in digest[1:16]; value=(value<<8)|UInt128(byte) end
    value
end

"""A resolved parameter selector, reusable with circuits sharing its topology."""
struct ParameterHandle{S}
    topology::HierarchicalCompiledTopology
    selector::S
    locations::Vector{Pair{Int,Vector{Int}}}
end

"""
    parameter_handle(compiled, selector) -> ParameterHandle

Resolve a selector such as `"stage[1:3].R1.value"` once for repeated updates.
Use `with_parameters(compiled, handle => value)`. A handle is bound to this
compiled topology and also accepts descendants produced by `with_parameters`.
Parameter values are validated when applied; another compiled topology is rejected.
"""
function parameter_handle(compiled,selector_text)
    selector=_parse_parameter_selector(String(selector_text))
    selector[4] in _STRUCTURAL_PARAMETER_NAMES && throw(TopologyParameterError(String(selector_text),selector[4]))
    locations=Pair{Int,Vector{Int}}[]
    for (index,batch) in enumerate(compiled.parameters.batches)
        indices=Int[]
        for (device,locator) in enumerate(batch.locators)
            instance_path,device_name=_locator_device_name(compiled.design,locator)
            _matches_selector(instance_path,device_name,selector[1],selector[2],selector[3]) && push!(indices,device)
        end
        isempty(indices) || push!(locations,index=>indices)
    end
    isempty(locations) && throw(KeyError(selector_text))
    ParameterHandle(compiled.topology,selector,locations)
end

"""
    with_parameters(compiled::CompiledCircuit, updates::Pair...) -> CompiledCircuit
    with_parameters(compiled::CompiledCircuit, updates::AbstractVector{<:Pair})

Return a new compiled circuit with numerical parameter updates, leaving the
original unchanged. Paths are strings or symbols such as `"R1.value"`,
`"Source.dc"`, or `"First.M1.width"`. Array selectors such as
`"stage[1:3].R1.value"` update several matching devices at once. Values use the
selected parameter's SI units.

```julia
compiled = compile(circuit)
tuned = with_parameters(compiled, "R1.value" => 2kΩ, "Source.dc" => 3.3V)
op = operating_point(tuned)
```

Untouched batches and all topology arrays are shared. Structural parameters are
rejected with `TopologyParameterError`: adding/changing package parasitics,
connections, or component counts requires rebuilding the design. Unknown paths
raise `KeyError`; incompatible numerical storage types raise
`ParameterUpdateError`. Model parameters such as MOS geometry are supported
where the model exposes them.

Updating a capacitor's `value` does not rescale expanded loss/absorption elements.
Rebuild if those should track the new capacitance. For a standalone model copy,
see [`with_model_parameter`](@ref); for repeated analyses see [`sweep`](@ref).
"""
function with_parameters(compiled, updates::Pair...)
    isempty(updates) && return compiled
    batches = collect(compiled.parameters.batches)
    touched=falses(length(batches)); matrix_changed=falses(length(batches))
    for (selector_text,value) in updates
        handle=selector_text isa ParameterHandle ? selector_text : parameter_handle(compiled,selector_text)
        handle.topology === compiled.topology || throw(ArgumentError("parameter handle belongs to a different compiled topology"))
        for (index,indices) in handle.locations
            updated=_updated_batch(batches[index],compiled.design,handle.selector[4],indices,value;
                owned=touched[index])
            batches[index]=updated; touched[index]=true
            kind=_batch_kind(updated)
            matrix_changed[index] |= !(kind in (:voltage_source,:current_source) &&
                handle.selector[4] in (:dc,:ac,:waveform))
        end
    end
    new_batches = Tuple(batches)
    hashes=copy(compiled.parameters.batch_fingerprints)
    matrix_hashes=copy(compiled.parameters.matrix_batch_fingerprints)
    for index in eachindex(batches)
        touched[index] && (hashes[index]=_parameter_store_fingerprint((batches[index],)))
        matrix_changed[index] && (matrix_hashes[index]=_matrix_parameter_fingerprint((batches[index],)))
    end
    store = ParameterStore(new_batches,_combine_parameter_fingerprints(hashes),
        _combine_parameter_fingerprints(matrix_hashes),hashes,matrix_hashes)
    fingerprint = bytes2hex(sha1(string(compiled.design.structural_fingerprint, ':', store.fingerprint)))
    CompiledCircuit(compiled.design, compiled.topology, store, fingerprint)
end

with_parameters(compiled, updates::AbstractVector{<:Pair}) = with_parameters(compiled, updates...)
