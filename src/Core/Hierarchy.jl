"""Common supertype for immutable circuit definitions."""
abstract type AbstractCircuitDefinition end

"""A design-local identifier. Dynamic user names are never interned as Julia `Symbol`s."""
struct NameId
    value::UInt32
end
NameId(value::Integer) = NameId(UInt32(value))
Base.Int(id::NameId) = Int(id.value)
Base.isless(a::NameId, b::NameId) = isless(a.value, b.value)

struct TemplateId
    value::UInt32
end
TemplateId(value::Integer) = TemplateId(UInt32(value))
Base.Int(id::TemplateId) = Int(id.value)

struct InstanceId
    value::UInt32
end
InstanceId(value::Integer) = InstanceId(UInt32(value))
Base.Int(id::InstanceId) = Int(id.value)

struct PathId
    value::UInt32
end
PathId(value::Integer) = PathId(UInt32(value))
Base.Int(id::PathId) = Int(id.value)

"""One path segment: `base` or `base[index]`. `index` may use any Julia array index."""
struct NameSegment
    base::NameId
    index::Any
end
NameSegment(base::NameId) = NameSegment(base, nothing)

abstract type AbstractElementPath end
struct InstancePath <: AbstractElementPath
    segments::Vector{Tuple{String,Any}}
end
struct NetPath <: AbstractElementPath
    segments::Vector{Tuple{String,Any}}
end
struct DevicePath <: AbstractElementPath
    segments::Vector{Tuple{String,Any}}
end

function _parse_segment(text::AbstractString)
    match_result = match(r"^([^\[\]]+)(?:\[(-?\d+)\])?$", text)
    match_result === nothing && throw(ArgumentError("invalid hierarchical path segment $(repr(text))"))
    (String(match_result.captures[1]), match_result.captures[2] === nothing ? nothing : parse(Int, match_result.captures[2]))
end
parsepath(text::AbstractString) = InstancePath(_parse_segment.(split(String(text), '.')))
_render_segment(segment::Tuple{String,Any}) = segment[2] === nothing ? segment[1] : "$(segment[1])[$(segment[2])]"
Base.string(path::AbstractElementPath) = join(_render_segment.(path.segments), '.')
Base.show(io::IO, path::AbstractElementPath) = print(io, string(path))

struct NameTable
    strings::Vector{String}
end
_name(table::NameTable, id::NameId) = table.strings[Int(id)]

mutable struct _NameBuilder
    strings::Vector{String}
    ids::Dict{String,NameId}
    static_ids::Dict{Symbol,NameId}
end
_NameBuilder() = _NameBuilder(String[], Dict{String,NameId}(), Dict{Symbol,NameId}())
function _intern!(table::_NameBuilder, value::AbstractString)
    text = String(value)
    get!(table.ids, text) do
        push!(table.strings, text)
        NameId(length(table.strings))
    end
end
function _intern!(table::_NameBuilder, value::Symbol)
    get!(table.static_ids, value) do
        id = _intern!(table, String(value))
        id
    end
end

function _name_segment!(table::_NameBuilder, value)
    if value isa Union{Symbol,AbstractString}
        return NameSegment(_intern!(table, value))
    elseif value isa Tuple && length(value) == 2 && first(value) isa Union{Symbol,AbstractString}
        return NameSegment(_intern!(table, first(value)), last(value))
    end
    throw(ArgumentError("a name must be a String, Symbol, or `(base, index)` tuple; got $(repr(value))"))
end

struct PortSpec
    name::NameId
    required::Bool
    reference::Bool
end
struct ParameterSpec
    name::NameId
    default::Any
    structural::Bool
end

abstract type AbstractParameterExpression end
struct ParameterReference <: AbstractParameterExpression
    name::NameId
end
struct ParameterLiteral <: AbstractParameterExpression
    value::Any
end
struct ParameterCall <: AbstractParameterExpression
    operation::UInt8
    arguments::Vector{AbstractParameterExpression}
end

const _PARAMETER_OPERATIONS = Dict{Symbol,UInt8}(
    :+ => 0x01, :- => 0x02, :* => 0x03, :/ => 0x04, :^ => 0x05,
    :sqrt => 0x06, :exp => 0x07, :log => 0x08, :abs => 0x09,
    :min => 0x0a, :max => 0x0b,
)
_parameter_expression(value::AbstractParameterExpression) = value
_parameter_expression(value) = ParameterLiteral(value)
_parameter_call(operation::Symbol, args...) = ParameterCall(_PARAMETER_OPERATIONS[operation], AbstractParameterExpression[_parameter_expression(arg) for arg in args])
for operation in (:+, :-, :*, :/, :^, :min, :max)
    @eval begin
        Base.$operation(a::AbstractParameterExpression, b) = _parameter_call($(QuoteNode(operation)), a, b)
        Base.$operation(a, b::AbstractParameterExpression) = _parameter_call($(QuoteNode(operation)), a, b)
    end
end
Base.:-(a::AbstractParameterExpression) = _parameter_call(:-, 0, a)
for operation in (:sqrt, :exp, :log, :abs)
    @eval Base.$operation(a::AbstractParameterExpression) = _parameter_call($(QuoteNode(operation)), a)
end

function _evaluate(expression::AbstractParameterExpression, values)
    expression isa ParameterReference && return values[expression.name]
    expression isa ParameterLiteral && return expression.value
    call = expression::ParameterCall
    args = map(argument -> _evaluate(argument, values), call.arguments)
    operation = call.operation
    operation == 0x01 && return +(args...)
    operation == 0x02 && return -(args...)
    operation == 0x03 && return *(args...)
    operation == 0x04 && return /(args...)
    operation == 0x05 && return ^(args...)
    operation == 0x06 && return sqrt(args...)
    operation == 0x07 && return exp(args...)
    operation == 0x08 && return log(args...)
    operation == 0x09 && return abs(args...)
    operation == 0x0a && return min(args...)
    operation == 0x0b && return max(args...)
    error("invalid parameter-expression operation $(operation)")
end

"""Compact builder handle. Ownership and generation are checked at every mutation boundary."""
struct BuilderNet <: AbstractNode
    owner::UInt64
    generation::UInt32
    id::Int32
    name::NameSegment
end
struct LocalNetReference
    id::Int32
end
struct LocalPrimitiveReference
    id::Int32
end

struct BuilderInstance
    owner::UInt64
    generation::UInt32
    id::InstanceId
end
struct BuilderPrimitive
    owner::UInt64
    generation::UInt32
    id::Int32
    name::NameId
end

struct ConnectionRange
    start::UInt32
    length::UInt16
end
struct ParameterRange
    start::UInt32
    length::UInt16
end

@enum PartitionHint::UInt8 begin
    PartitionAuto
    PartitionAtomic
    PartitionBoundary
end
PartitionHint(value::Symbol) = value === :auto ? PartitionAuto : value === :atomic ? PartitionAtomic : value === :boundary ? PartitionBoundary : throw(ArgumentError("partition must be :auto, :atomic, or :boundary"))

struct PrimitiveSpec{K,P}
    kernel::K
    terminals::UnitRange{Int32}
    parameters::P
    name::NameId
end

struct TemplateIR
    net_names::Vector{NameSegment}
    ground_net::Int32
    terminal_data::Vector{Int32}
    primitives::Vector{Any}
    observations::Vector{Any}
end

struct SubcircuitTemplate <: AbstractCircuitDefinition
    name::NameId
    ports::Vector{PortSpec}
    parameters::Vector{ParameterSpec}
    body::TemplateIR
    structural_fingerprint::UInt128
    names::NameTable
end

struct TemplateInvocation
    template::SubcircuitTemplate
    connections::Tuple
    parameters::NamedTuple
    instance_name::Any
    partition::PartitionHint
end


function (template::SubcircuitTemplate)(connections...; instance_name=nothing, partition=:auto, kwargs...)
    length(connections) == length(template.ports) || throw(ArgumentError("template expects $(length(template.ports)) port connections"))
    TemplateInvocation(template, connections, (; kwargs...), instance_name,
        partition isa PartitionHint ? partition : PartitionHint(partition))
end


instance(template::SubcircuitTemplate, connections...; instance_name, partition=:auto, kwargs...) =
    template(connections...; instance_name, partition, kwargs...)

struct TemplateRegistry
    templates::Vector{SubcircuitTemplate}
end

struct InstanceRecord
    template::TemplateId
    parent::InstanceId
    name::NameSegment
    connections::ConnectionRange
    parameters::ParameterRange
    partition_hint::PartitionHint
    path::PathId
end

struct InstanceGraph
    records::Vector{InstanceRecord}
    connection_data::Vector{Int32}
    parameter_data::Vector{Any}
end

struct ObservationSet
    values::Vector{Any}
end
struct DesignMetadata
    values::Dict{String,Any}
end

struct _PathNode
    parent::PathId
    segment::NameSegment
end
struct PathTrie
    nodes::Vector{_PathNode}
end

struct CircuitDesign <: AbstractCircuitDefinition
    name::NameId
    templates::TemplateRegistry
    root::InstanceGraph
    observations::ObservationSet
    metadata::DesignMetadata
    structural_fingerprint::UInt128
    parameter_fingerprint::UInt128
    names::NameTable
    root_ir::TemplateIR
    paths::PathTrie
end

const _BUILDER_OWNER = Threads.Atomic{UInt64}(0)
mutable struct CircuitBuilder
    owner::UInt64
    generation::UInt32
    mode::Symbol
    name::NameId
    names::_NameBuilder
    net_names::Vector{NameSegment}
    ground_net::Int32
    terminal_data::Vector{Int32}
    primitives::Vector{Any}
    observations::Vector{Any}
    templates::Vector{SubcircuitTemplate}
    template_ids::Dict{UInt128,TemplateId}
    instances::Vector{InstanceRecord}
    connections::Vector{Int32}
    parameters::Vector{Any}
    path_nodes::Vector{_PathNode}
    finished::Bool
end

function CircuitBuilder(name::Union{Symbol,AbstractString}=:anonymous; _mode::Symbol=:design)
    names = _NameBuilder()
    name_id = _intern!(names, name)
    owner = Threads.atomic_add!(_BUILDER_OWNER, UInt64(1)) + UInt64(1)
    CircuitBuilder(owner, 0x00000001, _mode, name_id, names, NameSegment[], Int32(0), Int32[], Any[], Any[],
        SubcircuitTemplate[], Dict{UInt128,TemplateId}(), InstanceRecord[], Int32[], Any[], _PathNode[], false)
end

struct BuilderOwnershipError <: Exception
    message::String
end
Base.showerror(io::IO, error::BuilderOwnershipError) = print(io, error.message)

function _assert_open(builder::CircuitBuilder)
    builder.finished && throw(BuilderOwnershipError("this CircuitBuilder has already been finished"))
end
function _assert_owned(builder::CircuitBuilder, handle)
    _assert_open(builder)
    handle.owner == builder.owner && handle.generation == builder.generation || throw(BuilderOwnershipError("handle belongs to another CircuitBuilder or generation"))
    handle
end

function node!(builder::CircuitBuilder, name::Union{Symbol,AbstractString}=(:n, length(builder.net_names) + 1))
    _assert_open(builder)
    segment = _name_segment!(builder.names, name)
    push!(builder.net_names, segment)
    BuilderNet(builder.owner, builder.generation, Int32(length(builder.net_names)), segment)
end
function node!(builder::CircuitBuilder, name::Tuple)
    _assert_open(builder)
    segment = _name_segment!(builder.names, name)
    push!(builder.net_names, segment)
    BuilderNet(builder.owner, builder.generation, Int32(length(builder.net_names)), segment)
end
function ground!(builder::CircuitBuilder, name::Union{Symbol,AbstractString}=:gnd)
    builder.ground_net == 0 || throw(ArgumentError("a CircuitBuilder may contain only one top-level reference net"))
    net = node!(builder, name)
    builder.ground_net = net.id
    net
end

struct NetArray{N,A<:Tuple}
    owner::UInt64
    generation::UInt32
    data::Vector{BuilderNet}
    array_axes::A
end
Base.axes(array::NetArray) = array.array_axes
Base.size(array::NetArray) = map(length, array.array_axes)
Base.length(array::NetArray) = length(array.data)
Base.IndexStyle(::Type{<:NetArray}) = IndexCartesian()
function _axis_position(axis, index)
    if axis isa AbstractUnitRange && index isa Integer
        position = Int(index - first(axis) + 1)
        1 <= position <= length(axis) && axis[position] == index || throw(BoundsError(axis, index))
        return position
    end
    position = findfirst(isequal(index), axis)
    position === nothing && throw(BoundsError(axis, index))
    position
end
function Base.getindex(array::NetArray, indices...)
    positions = ntuple(i -> _axis_position(array.array_axes[i], indices[i]), length(indices))
    linear = LinearIndices(map(length, array.array_axes))[positions...]
    array.data[linear]
end
Base.iterate(array::NetArray, state=1) = state > length(array.data) ? nothing : (array.data[state], state + 1)

function node_array!(builder::CircuitBuilder, name::Union{Symbol,AbstractString}, axes...)
    normalized = length(axes) == 1 && axes[1] isa Tuple ? axes[1] : axes
    isempty(normalized) && throw(ArgumentError("node_array! requires at least one axis"))
    data = BuilderNet[]
    sizehint!(data, prod(length, normalized))
    sizehint!(builder.net_names, length(builder.net_names) + prod(length, normalized))
    for index in CartesianIndices(normalized)
        display_index = length(normalized) == 1 ? index[1] : Tuple(index)
        push!(data, node!(builder, (name, display_index)))
    end
    NetArray{length(normalized),typeof(normalized)}(builder.owner, builder.generation, data, normalized)
end

function _builder_parameter(builder::CircuitBuilder, value)
    value isa BuilderNet && return (_assert_owned(builder, value); LocalNetReference(value.id))
    value isa Tuple && return Tuple(_builder_parameter(builder, item) for item in value)
    value isa NamedTuple && return NamedTuple{keys(value)}(Tuple(_builder_parameter(builder, item) for item in value))
    value isa AbstractVector && return [_builder_parameter(builder, item) for item in value]
    value
end

function _primitive_parameters(builder::CircuitBuilder, parameters::Dict{Symbol,Any})
    keys_ordered = sort!(collect(keys(parameters)); by=String)
    names = Tuple(keys_ordered)
    NamedTuple{names}(Tuple(_builder_parameter(builder, parameters[key]) for key in keys_ordered))
end

function add!(builder::CircuitBuilder, component::Component; name::Union{Symbol,AbstractString}=Symbol(component.kind, length(builder.primitives) + 1))
    _assert_open(builder)
    terminals = Int32[]
    for terminal in component.terminals
        terminal isa BuilderNet || throw(BuilderOwnershipError("primitive terminals added to a CircuitBuilder must be builder net handles"))
        _assert_owned(builder, terminal)
        push!(terminals, terminal.id)
    end
    start = Int32(length(builder.terminal_data) + 1)
    append!(builder.terminal_data, terminals)
    name_id = _intern!(builder.names, name)
    parameters = _primitive_parameters(builder, component.parameters)
    kernel = Val(component.kind)
    stop = start + Int32(length(terminals) - 1)
    push!(builder.primitives, PrimitiveSpec(kernel, start:stop, parameters, name_id))
    BuilderPrimitive(builder.owner, builder.generation, Int32(length(builder.primitives)), name_id)
end

function observe!(builder::CircuitBuilder, values...; name=nothing)
    _assert_open(builder)
    for value in values
        value isa BuilderNet && _assert_owned(builder, value)
        push!(builder.observations, (name=name === nothing ? nothing : String(name), value=value))
    end
    isempty(values) ? builder : last(values)
end

function _register_template!(builder::CircuitBuilder, template::SubcircuitTemplate)
    get!(builder.template_ids, template.structural_fingerprint) do
        push!(builder.templates, template)
        TemplateId(length(builder.templates))
    end
end

function _named_values(specs, table::NameTable, supplied, what::AbstractString)
    supplied isa NamedTuple || (supplied = (; supplied...))
    supplied_names = keys(supplied)
    expected_names = Tuple(Symbol(_name(table, spec.name)) for spec in specs)
    unknown = setdiff(supplied_names, expected_names)
    isempty(unknown) || throw(ArgumentError("unknown $(what)(s): $(join(string.(unknown), ", "))"))
    output = Any[]
    for spec in specs
        name = Symbol(_name(table, spec.name))
        if hasproperty(supplied, name)
            push!(output, getproperty(supplied, name))
        elseif spec isa ParameterSpec
            push!(output, spec.default)
        else
            throw(ArgumentError("missing required $(what) $(String(name))"))
        end
    end
    output
end

function instance!(builder::CircuitBuilder, template::SubcircuitTemplate;
        instance_name, connections, parameters=NamedTuple(), partition=:auto, parent=InstanceId(0))
    _assert_open(builder)
    template_id = _register_template!(builder, template)
    connections isa NamedTuple || (connections = (; connections...))
    parameters isa NamedTuple || (parameters = (; parameters...))
    port_names = Tuple(Symbol(_name(template.names, spec.name)) for spec in template.ports)
    keys(connections) == port_names || throw(ArgumentError("connections must provide ports $(port_names) in declaration order"))
    parameter_names = Tuple(Symbol(_name(template.names, spec.name)) for spec in template.parameters)
    unknown_parameters = setdiff(keys(parameters), parameter_names)
    isempty(unknown_parameters) || throw(ArgumentError("unknown parameter(s): $(join(string.(unknown_parameters), ", "))"))
    _append_instance!(builder, template, template_id, instance_name, connections, parameters,
        partition isa PartitionHint ? partition : PartitionHint(partition), parent, parameter_names)
end

function _append_instance!(builder::CircuitBuilder, template::SubcircuitTemplate, template_id::TemplateId,
        instance_name, connections::NamedTuple, parameters::NamedTuple, partition::PartitionHint,
        parent::InstanceId, parameter_names)
    connection_start = UInt32(length(builder.connections) + 1)
    for connection in values(connections)
        connection isa BuilderNet || throw(BuilderOwnershipError("instance connections must be net handles from the receiving builder"))
        _assert_owned(builder, connection); push!(builder.connections, connection.id)
    end
    parameter_start = UInt32(length(builder.parameters) + 1)
    for (name, spec) in zip(parameter_names, template.parameters)
        push!(builder.parameters, hasproperty(parameters, name) ? getproperty(parameters, name) : spec.default)
    end
    segment = _name_segment!(builder.names, instance_name)
    parent_path = parent.value == 0 ? PathId(0) : builder.instances[Int(parent)].path
    push!(builder.path_nodes, _PathNode(parent_path, segment))
    record = InstanceRecord(template_id, parent, segment,
        ConnectionRange(connection_start, UInt16(length(template.ports))),
        ParameterRange(parameter_start, UInt16(length(template.parameters))),
        partition, PathId(length(builder.path_nodes)))
    push!(builder.instances, record)
    BuilderInstance(builder.owner, builder.generation, InstanceId(length(builder.instances)))
end

function instance!(builder::CircuitBuilder, template::SubcircuitTemplate, connections::BuilderNet...;
        instance_name, partition=:auto, kwargs...)
    length(connections) == length(template.ports) || throw(ArgumentError("template expects $(length(template.ports)) port connections"))
    connection_tuple = NamedTuple{Tuple(Symbol(_name(template.names, port.name)) for port in template.ports)}(connections)
    instance!(builder, template; instance_name, connections=connection_tuple, parameters=(; kwargs...), partition)
end

function instance!(builder::CircuitBuilder, invocation::TemplateInvocation; instance_name=invocation.instance_name)
    instance_name === nothing && throw(ArgumentError("an explicit instance name is required outside @circuit assignment inference"))
    instance!(builder, invocation.template, invocation.connections...; instance_name,
        partition=invocation.partition, invocation.parameters...)
end

function _attach!(parent::Circuit, invocation::TemplateInvocation; name=:value)
    template = invocation.template
    chosen_name = invocation.instance_name === nothing ? name : invocation.instance_name
    prefix = chosen_name isa Tuple ? _render_segment((String(first(chosen_name)), last(chosen_name))) : String(chosen_name)
    netmap = Dict{Int,AbstractNode}(index => connection for (index, connection) in enumerate(invocation.connections))
    for local_index in (length(template.ports) + 1):length(template.body.net_names)
        segment = template.body.net_names[local_index]
        local_name = _render_segment((_name(template.names, segment.base), segment.index))
        netmap[local_index] = node!(parent, Symbol(prefix, ".", local_name))
    end
    supplied = _named_values(template.parameters, template.names, invocation.parameters, "parameter")
    values = Dict(parameter.name => supplied[index] for (index, parameter) in enumerate(template.parameters))
    componentmap = Any[]
    for primitive in template.body.primitives
        terminals = AbstractNode[netmap[Int(local_id)] for local_id in template.body.terminal_data[primitive.terminals]]
        parameters = Dict{Symbol,Any}(pairs(_materialize_parameter(primitive.parameters, values)))
        component_name = Symbol(prefix, ".", _name(template.names, primitive.name))
        push!(componentmap, add!(parent, Component(typeof(primitive.kernel).parameters[1], terminals, parameters, component_name); name=component_name))
    end
    invocation
end

struct InstanceArray{N,A<:Tuple}
    owner::UInt64
    generation::UInt32
    data::Vector{BuilderInstance}
    array_axes::A
end
Base.axes(array::InstanceArray) = array.array_axes
Base.size(array::InstanceArray) = map(length, array.array_axes)
Base.length(array::InstanceArray) = length(array.data)
function Base.getindex(array::InstanceArray, indices...)
    positions = ntuple(i -> _axis_position(array.array_axes[i], indices[i]), length(indices))
    array.data[LinearIndices(map(length, array.array_axes))[positions...]]
end
Base.iterate(array::InstanceArray, state=1) = state > length(array.data) ? nothing : (array.data[state], state + 1)

function instances!(builder::CircuitBuilder, template::SubcircuitTemplate, axis;
        name, connections, parameters=(_ -> NamedTuple()), partition=:auto)
    data = BuilderInstance[]
    count = length(axis)
    sizehint!(data, count)
    sizehint!(builder.instances, length(builder.instances) + count)
    sizehint!(builder.path_nodes, length(builder.path_nodes) + count)
    sizehint!(builder.connections, length(builder.connections) + count * length(template.ports))
    sizehint!(builder.parameters, length(builder.parameters) + count * length(template.parameters))
    template_id = _register_template!(builder, template)
    port_names = Tuple(Symbol(_name(template.names, spec.name)) for spec in template.ports)
    parameter_names = Tuple(Symbol(_name(template.names, spec.name)) for spec in template.parameters)
    for index in axis
        hint = partition isa Function ? partition(index) : partition
        connection_values = connections(index)
        connection_values isa NamedTuple || (connection_values = (; connection_values...))
        keys(connection_values) == port_names || throw(ArgumentError("connections must provide ports $(port_names) in declaration order"))
        parameter_values = parameters(index)
        parameter_values isa NamedTuple || (parameter_values = (; parameter_values...))
        all(key -> key in parameter_names, keys(parameter_values)) || throw(ArgumentError("unknown instance parameter"))
        push!(data, _append_instance!(builder, template, template_id, name(index), connection_values,
            parameter_values, hint isa PartitionHint ? hint : PartitionHint(hint), InstanceId(0), parameter_names))
    end
    normalized_axes = (axis,)
    InstanceArray{1,typeof(normalized_axes)}(builder.owner, builder.generation, data, normalized_axes)
end

function _fingerprint128(parts...)
    digest = sha256(join(string.(parts), '\x1f'))
    value = zero(UInt128)
    for byte in digest[1:16]
        value = (value << 8) | UInt128(byte)
    end
    value
end

function _design_fingerprints(builder::CircuitBuilder, root_fingerprint::UInt128)
    structural_io = IOBuffer(sizehint=max(1024, 48 * length(builder.instances)))
    print(structural_io, root_fingerprint, '|')
    for template in builder.templates
        print(structural_io, template.structural_fingerprint, ';')
    end
    for record in builder.instances
        print(structural_io, record.template.value, ',', record.parent.value, ',', record.name.base.value, ',', repr(record.name.index), ':')
        first_connection = Int(record.connections.start)
        last_connection = first_connection + Int(record.connections.length) - 1
        for connection in @view builder.connections[first_connection:last_connection]
            print(structural_io, connection, ',')
        end
        write(structural_io, UInt8(';'))
    end
    parameter_io = IOBuffer(sizehint=max(256, 16 * length(builder.parameters)))
    for parameter in builder.parameters
        print(parameter_io, repr(parameter), ';')
    end
    structural_digest = sha256(take!(structural_io))
    parameter_digest = sha256(take!(parameter_io))
    to_uint128 = digest -> begin
        value = zero(UInt128)
        for byte in digest[1:16]
            value = (value << 8) | UInt128(byte)
        end
        value
    end
    to_uint128(structural_digest), to_uint128(parameter_digest)
end

function _root_fingerprint(builder::CircuitBuilder, names::NameTable, body::TemplateIR)
    io = IOBuffer(sizehint=max(512, 16 * length(body.net_names) + 48 * length(body.primitives)))
    print(io, _name(names, builder.name), '|', body.ground_net, '|')
    for segment in body.net_names
        print(io, segment.base.value, '[', repr(segment.index), "];" )
    end
    for primitive in body.primitives
        print(io, typeof(primitive.kernel).parameters[1], ':', primitive.name.value, ':')
        for terminal in @view body.terminal_data[primitive.terminals]
            print(io, terminal, ',')
        end
        print(io, repr(primitive.parameters), ';')
    end
    digest = sha256(take!(io)); value = zero(UInt128)
    for byte in digest[1:16]
        value = (value << 8) | UInt128(byte)
    end
    value
end

function _template_signature(name, ports, parameters, body, names)
    primitive_signature = [(primitive.kernel, collect(body.terminal_data[primitive.terminals]), primitive.parameters, _name(names, primitive.name)) for primitive in body.primitives]
    (name, [(_name(names, port.name), port.required, port.reference) for port in ports],
        [(_name(names, parameter.name), parameter.default, parameter.structural) for parameter in parameters],
        [(segment.base.value, segment.index) for segment in body.net_names], primitive_signature)
end

function finish(builder::CircuitBuilder)
    _assert_open(builder)
    builder.finished = true
    builder.generation += 1
    names = NameTable(copy(builder.names.strings))
    body = TemplateIR(copy(builder.net_names), builder.ground_net, copy(builder.terminal_data), copy(builder.primitives), copy(builder.observations))
    if builder.mode === :template
        error("internal template builder requires port and parameter specifications")
    end
    root_fingerprint = _root_fingerprint(builder, names, body)
    structural, parameter = _design_fingerprints(builder, root_fingerprint)
    CircuitDesign(builder.name, TemplateRegistry(copy(builder.templates)),
        InstanceGraph(copy(builder.instances), copy(builder.connections), copy(builder.parameters)),
        ObservationSet(copy(builder.observations)), DesignMetadata(Dict{String,Any}()), structural, parameter,
        names, body, PathTrie(copy(builder.path_nodes)))
end

function _finish_template(builder::CircuitBuilder, ports::Vector{PortSpec}, parameters::Vector{ParameterSpec})
    _assert_open(builder)
    builder.finished = true
    builder.generation += 1
    names = NameTable(copy(builder.names.strings))
    body = TemplateIR(copy(builder.net_names), builder.ground_net, copy(builder.terminal_data), copy(builder.primitives), copy(builder.observations))
    signature = _template_signature(_name(names, builder.name), ports, parameters, body, names)
    SubcircuitTemplate(builder.name, ports, parameters, body, _fingerprint128(signature), names)
end

function _define_subcircuit(f::Function, name::Symbol, port_names::Tuple, defaults::Tuple)
    builder = CircuitBuilder(name; _mode=:template)
    ports = BuilderNet[]
    port_specs = PortSpec[]
    for port_name in port_names
        net = node!(builder, port_name)
        push!(ports, net); push!(port_specs, PortSpec(net.name.base, true, false))
    end
    parameter_specs = ParameterSpec[]
    references = AbstractParameterExpression[]
    for (parameter_name, default) in defaults
        id = _intern!(builder.names, parameter_name)
        push!(parameter_specs, ParameterSpec(id, default, false)); push!(references, ParameterReference(id))
    end
    port_tuple = NamedTuple{port_names}(Tuple(ports))
    parameter_names = Tuple(first(item) for item in defaults)
    parameter_tuple = NamedTuple{parameter_names}(Tuple(references))
    f(builder, port_tuple, parameter_tuple)
    _finish_template(builder, port_specs, parameter_specs)
end

const _HIERARCHY_PRIMITIVES = (:resistor, :capacitor, :inductor, :conductance, :voltage_source, :current_source,
    :transconductance, :voltage_controlled_voltage_source, :current_controlled_current_source,
    :current_controlled_voltage_source, :diode, :npn, :nmos, :pmos, :opamp, :analog_switch)

function _template_macro_rewrite(expression, builder)
    expression isa Expr || return expression
    if expression.head === :(=) && expression.args[1] isa Symbol && expression.args[2] isa Expr && expression.args[2].head === :call
        name = expression.args[1]; call = expression.args[2]
        call.args[1] in _HIERARCHY_PRIMITIVES && return :($name = add!($builder, $call; name=$(QuoteNode(name))))
    elseif expression.head === :call && expression.args[1] === :observe
        arguments = Any[expression.args[2:end]...]
        if !isempty(arguments) && arguments[1] isa Expr && arguments[1].head === :parameters
            return Expr(:call, :observe!, arguments[1], builder, arguments[2:end]...)
        end
        return Expr(:call, :observe!, builder, arguments...)
    elseif expression.head === :call && expression.args[1] in _HIERARCHY_PRIMITIVES
        return :(add!($builder, $expression))
    elseif expression.head === :block
        return Expr(:block, map(item -> _template_macro_rewrite(item, builder), expression.args)...)
    elseif expression.head in (:for, :while)
        return Expr(expression.head, expression.args[1], _template_macro_rewrite(expression.args[2], builder))
    elseif expression.head === :if
        return Expr(:if, expression.args[1], map(item -> _template_macro_rewrite(item, builder), expression.args[2:end])...)
    end
    expression
end

macro subcircuit(signature, block)
    signature isa Expr && signature.head === :call || error("@subcircuit requires a function-like signature")
    name = signature.args[1]
    name isa Symbol || error("@subcircuit name must be a Symbol")
    ports = Symbol[]
    parameter_names = Symbol[]
    defaults = Expr[]
    for argument in signature.args[2:end]
        if argument isa Expr && argument.head === :parameters
            for keyword in argument.args
                keyword isa Expr && keyword.head in (:(=), :kw) || error("template parameters require defaults")
                push!(parameter_names, keyword.args[1])
                push!(defaults, :($(QuoteNode(keyword.args[1])) => $(keyword.args[2])))
            end
        elseif argument isa Symbol
            push!(ports, argument)
        else
            error("subcircuit ports must be identifiers")
        end
    end
    builder = gensym(:builder); port_values = gensym(:ports); parameter_values = gensym(:parameters)
    bindings = Any[:($(port) = getproperty($port_values, $(QuoteNode(port)))) for port in ports]
    append!(bindings, [:($(parameter) = getproperty($parameter_values, $(QuoteNode(parameter)))) for parameter in parameter_names])
    rewritten = _template_macro_rewrite(block, builder)
    define_subcircuit = GlobalRef(@__MODULE__, :_define_subcircuit)
    definition = quote
        const $(name) = $define_subcircuit($(QuoteNode(name)), $(Expr(:tuple, map(QuoteNode, ports)...)), $(Expr(:tuple, defaults...))) do $builder, $port_values, $parameter_values
            $(bindings...)
            $rewritten
            nothing
        end
    end
    esc(definition)
end

function _path_segments(design::CircuitDesign, path::PathId)
    output = Tuple{String,Any}[]
    current = path
    while current.value != 0
        node = design.paths.nodes[Int(current)]
        push!(output, (_name(design.names, node.segment.base), node.segment.index))
        current = node.parent
    end
    reverse!(output)
end

function _primitive_count(template::SubcircuitTemplate)
    length(template.body.primitives)
end

function Base.summary(design::CircuitDesign)
    counts = Dict{UInt32,Int}()
    for record in design.root.records
        counts[record.template.value] = get(counts, record.template.value, 0) + 1
    end
    primitive_count = length(design.root_ir.primitives)
    for (template_id, count) in counts
        primitive_count += count * _primitive_count(design.templates.templates[Int(template_id)])
    end
    (name=_name(design.names, design.name), templates=length(design.templates.templates), instances=length(design.root.records),
        nets=length(design.root_ir.net_names), primitive_devices=primitive_count,
        structural_fingerprint=design.structural_fingerprint, parameter_fingerprint=design.parameter_fingerprint)
end

function Base.instances(design::CircuitDesign; under=nothing, template=nothing, limit::Integer=100)
    output = NamedTuple[]
    for (index, record) in enumerate(design.root.records)
        path = InstancePath(_path_segments(design, record.path))
        under !== nothing && !startswith(string(path), string(under)) && continue
        template_value = design.templates.templates[Int(record.template)]
        template !== nothing && _name(template_value.names, template_value.name) != String(template) && continue
        push!(output, (id=InstanceId(index), path=path, template=_name(template_value.names, template_value.name), partition=record.partition_hint))
        length(output) >= limit && break
    end
    output
end

function devices(design::CircuitDesign; under=nothing, kind=nothing, limit::Integer=100)
    output = NamedTuple[]
    for (instance_index, record) in enumerate(design.root.records)
        prefix = _path_segments(design, record.path)
        under !== nothing && !startswith(string(InstancePath(prefix)), string(under)) && continue
        template = design.templates.templates[Int(record.template)]
        for primitive in template.body.primitives
            primitive_kind = typeof(primitive.kernel).parameters[1]
            kind !== nothing && primitive_kind != kind && continue
            path = DevicePath(vcat(prefix, [(_name(template.names, primitive.name), nothing)]))
            push!(output, (instance=InstanceId(instance_index), path, kind=primitive_kind))
            length(output) >= limit && return output
        end
    end
    output
end

function nets(design::CircuitDesign; under=nothing, floating=false, limit::Integer=100)
    output = NamedTuple[]
    for (index, segment) in enumerate(design.root_ir.net_names)
        path = NetPath([(_name(design.names, segment.base), segment.index)])
        push!(output, (id=Int32(index), path, ground=Int32(index) == design.root_ir.ground_net))
        length(output) >= limit && break
    end
    output
end

struct ResolvedElement
    kind::Symbol
    path::AbstractElementPath
    instance::Union{Nothing,InstanceId}
    local_index::Int
end

function resolve(design::CircuitDesign, path_value::Union{AbstractString,AbstractElementPath})
    path = path_value isa AbstractString ? parsepath(path_value) : path_value
    target = string(path)
    for (index, record) in enumerate(design.root.records)
        instance_path = InstancePath(_path_segments(design, record.path))
        string(instance_path) == target && return ResolvedElement(:instance, instance_path, InstanceId(index), index)
        prefix = string(instance_path) * "."
        startswith(target, prefix) || continue
        local_name = target[length(prefix)+1:end]
        template = design.templates.templates[Int(record.template)]
        for (primitive_index, primitive) in enumerate(template.body.primitives)
            _name(template.names, primitive.name) == local_name && return ResolvedElement(:device, DevicePath(path.segments), InstanceId(index), primitive_index)
        end
    end
    for (index, net) in enumerate(nets(design; limit=typemax(Int)))
        string(net.path) == target && return ResolvedElement(:net, net.path, nothing, index)
    end
    throw(KeyError(target))
end

function describe(design::CircuitDesign; depth::Integer=2, limit::Integer=100)
    info = summary(design)
    io = IOBuffer()
    println(io, "CircuitDesign: ", info.name)
    println(io, "Templates: ", info.templates)
    println(io, "Instances: ", info.instances)
    println(io, "Primitive devices: ", info.primitive_devices)
    if depth > 0
        for item in Base.instances(design; limit)
            println(io, "  ", item.path, " :: ", item.template)
        end
        info.instances > limit && println(io, "  … ", info.instances - limit, " more instances")
    end
    String(take!(io))
end
