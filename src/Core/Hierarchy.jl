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

"""Immutable reusable circuit template with explicit ports and parameters."""
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
Base.length(observations::ObservationSet)=length(observations.values)
Base.iterate(observations::ObservationSet,state...)=iterate(observations.values,state...)
Base.getindex(observations::ObservationSet,index)=observations.values[index]
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

"""Immutable hierarchical circuit definition produced by `finish` or `@circuit`."""
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
"""Mutable construction context; call `finish` to produce a `CircuitDesign`."""
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
    handle.owner == builder.owner || throw(BuilderOwnershipError(
        "cannot use a node or device handle from another CircuitBuilder; create the handle with node!(this_builder, ...) or ground!(this_builder, ...)"))
    handle.generation == builder.generation || throw(BuilderOwnershipError(
        "this builder handle is stale; obtain a new handle from the current CircuitBuilder generation"))
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

function _primitive_parameters(builder::CircuitBuilder, parameters)
    keys_ordered = sort!(collect(keys(parameters)); by=String)
    names = Tuple(keys_ordered)
    NamedTuple{names}(Tuple(_builder_parameter(builder, parameters[key]) for key in keys_ordered))
end

function _add_raw!(builder::CircuitBuilder, component::PrimitiveDraft, name)
    _assert_open(builder)
    terminals = Int32[]
    for terminal in component.terminals
        terminal isa BuilderNet || throw(BuilderOwnershipError("primitive terminals added to a CircuitBuilder must be builder net handles"))
        _assert_owned(builder, terminal)
        push!(terminals, terminal.id)
    end
    start = Int32(length(builder.terminal_data) + 1)
    append!(builder.terminal_data, terminals)
    segment = _name_segment!(builder.names, name)
    name_id = _intern!(builder.names, _render_segment((builder.names.strings[Int(segment.base)],segment.index)))
    parameters = _primitive_parameters(builder, component.parameters)
    kernel = Val(_draft_kind(component))
    stop = start + Int32(length(terminals) - 1)
    push!(builder.primitives, PrimitiveSpec(kernel, start:stop, parameters, name_id))
    BuilderPrimitive(builder.owner, builder.generation, Int32(length(builder.primitives)), name_id)
end

_model_value(model,key,default=0.)=model===nothing ? default : get(model.data,key,default)
_without(parameters::NamedTuple,removed::Tuple)=begin
    retained=Tuple(key for key in keys(parameters) if key ∉ removed)
    NamedTuple{retained}(Tuple(getproperty(parameters,key) for key in retained))
end
_hidden_name(name,suffix)=string(name,'.',suffix)

function _check_package_fields(kind,package,unused)
    package===nothing&&return
    for parameter in unused
        iszero(getproperty(package,parameter))||throw(ArgumentError(
            "$(kind) does not use package.$(parameter); omit it or set it to zero"))
    end
end

function add!(builder::CircuitBuilder, component::PrimitiveDraft; name=string(_draft_kind(component),length(builder.primitives) + 1))
    kind=_draft_kind(component); parameters=component.parameters; terminals=component.terminals
    kind in _CATALOG_COMPOSITES && return _add_catalog!(builder,component,name)
    hasproperty(parameters,:tolerance)&&_finite_nonnegative_parameter(:tolerance,parameters.tolerance)
    if hasproperty(parameters,:match)
        match=parameters.match
        match===nothing || match isa MatchedGroup || throw(ArgumentError("npn.match requires a MatchedGroup"))
    end
    for key in (:model,:material,:package,:dielectric,:dielectric_absorption)
        hasproperty(parameters,key)||continue
        value=getproperty(parameters,key)
        value===nothing&&continue
        expected=key===:material ? AbstractResistorMaterial :
            key===:package ? AbstractPassivePackage :
            key===:dielectric ? AbstractCapacitorDielectric :
            key===:dielectric_absorption ? DebyeBranches : nothing
        expected===nothing || value isa expected ||
            throw(ArgumentError("$(kind).$(key) requires a $(expected)"))
        _validate_model_parameters(value)
    end
    if kind===:resistor
        package=get(parameters,:package,nothing)
        _check_package_fields(kind,package,(:esr,:esl))
        series_inductance=_model_value(package,:series_inductance)
        parallel_capacitance=_model_value(package,:parallel_capacitance)
        main=if series_inductance>0
            internal=node!(builder,_hidden_name(name,"__series"))
            handle=_add_raw!(builder,_component(:resistor,terminals[1],internal;parameters...),name)
            _add_raw!(builder,inductor(internal,terminals[2];value=series_inductance),_hidden_name(name,"package_inductance")); handle
        else
            _add_raw!(builder,component,name)
        end
        parallel_capacitance>0&&_add_raw!(builder,capacitor(terminals[1],terminals[2];value=parallel_capacitance),_hidden_name(name,"package_capacitance"))
        return main
    elseif kind===:capacitor
        package=get(parameters,:package,nothing)
        _check_package_fields(kind,package,(:series_inductance,:parallel_capacitance))
        esr=Float64(get(parameters,:esr,_model_value(package,:esr)))
        esl=Float64(get(parameters,:esl,_model_value(package,:esl)))
        dielectric=get(parameters,:dielectric,nothing)
        if dielectric isa AbstractCapacitorDielectric && dielectric.loss_tangent>0
            # A constant series resistor calibrated at one frequency, usable in
            # every analysis (including transient and thermal noise).
            capacitance=parameters.value
            isfinite(capacitance)&&capacitance>0 ||
                throw(ArgumentError("dielectric loss requires finite positive capacitance"))
            esr += dielectric.loss_tangent/(2π*dielectric.reference_frequency*capacitance)
        end
        _finite_nonnegative_parameter(:esr,esr)
        _finite_nonnegative_parameter(:esl,esl)
        leakage=Float64(get(parameters,:leakage_resistance,Inf))
        leakage>0||throw(ArgumentError("leakage_resistance must be positive or Inf"))
        terminal=terminals[1]
        if esr>0
            following=node!(builder,_hidden_name(name,"__esr"))
            _add_raw!(builder,resistor(terminal,following;value=esr),_hidden_name(name,"esr")); terminal=following
        end
        if esl>0
            following=node!(builder,_hidden_name(name,"__esl"))
            _add_raw!(builder,inductor(terminal,following;value=esl),_hidden_name(name,"esl")); terminal=following
        end
        main_parameters=_without(parameters,(:esr,:esl,:leakage_resistance))
        main=_add_raw!(builder,_component(:capacitor,terminal,terminals[2];main_parameters...),name)
        isfinite(leakage)&&leakage>0&&_add_raw!(builder,resistor(terminal,terminals[2];value=leakage),_hidden_name(name,"leakage_resistance"))
        absorption=get(parameters,:dielectric_absorption,nothing)
        if absorption isa DebyeBranches
            length(absorption.time_constants)==length(absorption.fractions)||throw(ArgumentError("Debye time constants and fractions must have equal lengths"))
            for (index,(time_constant,fraction)) in enumerate(zip(absorption.time_constants,absorption.fractions))
                fraction>0||continue
                branch_capacitance=Float64(parameters.value)*fraction
                branch_node=node!(builder,_hidden_name(name,"__da$(index)"))
                _add_raw!(builder,resistor(terminal,branch_node;value=time_constant/branch_capacitance),_hidden_name(name,"da$(index)_resistor"))
                _add_raw!(builder,capacitor(branch_node,terminals[2];value=branch_capacitance),_hidden_name(name,"da$(index)_capacitor"))
            end
        end
        return main
    elseif kind===:inductor
        hasproperty(parameters,:winding_resistance)&&hasproperty(parameters,:series_resistance)&&
            throw(ArgumentError("specify only one of winding_resistance and series_resistance"))
        resistance=Float64(get(parameters,:winding_resistance,get(parameters,:series_resistance,0.)))
        parallel_capacitance=Float64(get(parameters,:parallel_capacitance,0.))
        _finite_nonnegative_parameter(:winding_resistance,resistance)
        _finite_nonnegative_parameter(:parallel_capacitance,parallel_capacitance)
        main=if resistance>0
            internal=node!(builder,_hidden_name(name,"__winding"))
            handle=_add_raw!(builder,_component(:inductor,terminals[1],internal;parameters...),name)
            _add_raw!(builder,resistor(internal,terminals[2];value=resistance),_hidden_name(name,"winding_resistance")); handle
        else
            _add_raw!(builder,component,name)
        end
        parallel_capacitance>0&&_add_raw!(builder,capacitor(terminals[1],terminals[2];value=parallel_capacitance),_hidden_name(name,"parallel_capacitance"))
        return main
    elseif kind===:diode&&parameters.model.series_resistance>0
        internal=node!(builder,_hidden_name(name,"__series"))
        _add_raw!(builder,resistor(terminals[1],internal;value=parameters.model.series_resistance),_hidden_name(name,"series_resistance"))
        return _add_raw!(builder,_component(:diode,internal,terminals[2];parameters...),name)
    elseif kind===:npn&&parameters.model.base_resistance>0
        internal=node!(builder,_hidden_name(name,"__base"))
        main=_add_raw!(builder,_component(:npn,terminals[1],internal,terminals[3];parameters...),name)
        _add_raw!(builder,resistor(terminals[2],internal;value=parameters.model.base_resistance),_hidden_name(name,"base_resistance"))
        return main
    end
    main=_add_raw!(builder,component,name)
    if kind===:switch&&parameters.model.clock_feedthrough>0
        _add_raw!(builder,capacitor(terminals[3],terminals[2];value=parameters.model.clock_feedthrough),_hidden_name(name,"clock_feedthrough"))
    elseif kind===:opamp
        model=parameters.model
        model.input_capacitance>0&&_add_raw!(builder,capacitor(terminals[1],terminals[2];value=model.input_capacitance),_hidden_name(name,"input_capacitance"))
        if model.input_bias_current!=0
            _add_raw!(builder,current_source(terminals[1],terminals[5];dc=model.input_bias_current),_hidden_name(name,"positive_bias_current"))
            _add_raw!(builder,current_source(terminals[2],terminals[5];dc=model.input_bias_current),_hidden_name(name,"negative_bias_current"))
        end
    end
    main
end

function _set_initial_voltage!(builder::CircuitBuilder, primitive::BuilderPrimitive, value)
    _assert_owned(builder,primitive)
    specification=builder.primitives[Int(primitive.id)]
    kind=typeof(specification.kernel).parameters[1]
    kind===:capacitor||throw(ArgumentError("initial_voltage applies only to capacitors"))
    parameters=merge(specification.parameters,(initial_voltage=_builder_parameter(builder,value),))
    builder.primitives[Int(primitive.id)]=PrimitiveSpec(specification.kernel,specification.terminals,parameters,specification.name)
    primitive
end

function _attach_value!(builder::CircuitBuilder,value,name=nothing)
    value isa PrimitiveDraft&&return add!(builder,value;name=name===nothing ? string(_draft_kind(value),length(builder.primitives)+1) : name)
    value isa TemplateInvocation&&return instance!(builder,value;instance_name=name===nothing ? value.instance_name : name)
    value
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

"""Finish a top-level builder and return its immutable `CircuitDesign`."""
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
    :current_controlled_voltage_source, :diode, :npn, :nmos, :pmos, :opamp, :analog_switch,
    :behavioral_current_source, :behavioral_voltage_source,
    :zener, :schottky, :led, :photodiode, :solar_cell, :njfet, :pjfet,
    :analog_multiplier, :voltage_limiter, :comparator, :voltage_controlled_resistor,
    :varistor, :thermistor, :potentiometer, :ideal_transformer, :bridge_rectifier, :crystal, :transmission_line)

function _template_macro_rewrite(expression, builder)
    expression isa Expr || return expression
    if expression.head === :(=) && expression.args[1] isa Symbol && expression.args[2] isa Expr && expression.args[2].head === :call
        name = expression.args[1]; call = expression.args[2]
        call.args[1] === :node && return :($name = node!($builder, $(QuoteNode(name))))
        call.args[1] === :ground && return :(throw(ArgumentError(
            "ground() is not allowed inside @subcircuit; add an explicit reference port and connect it at the top level")))
        call.args[1] in _HIERARCHY_PRIMITIVES && return :($name = add!($builder, $call; name=$(QuoteNode(name))))
    elseif expression.head === :call && expression.args[1] === :observe
        arguments = Any[expression.args[2:end]...]
        if !isempty(arguments) && arguments[1] isa Expr && arguments[1].head === :parameters
            return Expr(:call, :observe!, arguments[1], builder, arguments[2:end]...)
        end
        return Expr(:call, :observe!, builder, arguments...)
    elseif expression.head === :call && expression.args[1] === :initial_voltage
        return Expr(:call,GlobalRef(@__MODULE__, :_set_initial_voltage!),builder,expression.args[2:end]...)
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

function _design_macro_rewrite(expression,builder)
    expression isa Expr||return expression
    attach=GlobalRef(@__MODULE__, :_attach_value!)
    set_initial=GlobalRef(@__MODULE__, :_set_initial_voltage!)
    if expression.head===:(=)&&expression.args[1] isa Symbol&&expression.args[2] isa Expr&&expression.args[2].head===:call
        name=expression.args[1]; call=expression.args[2]; function_name=call.args[1]
        function_name===:node&&return :($name=node!($builder,$(QuoteNode(name))))
        function_name===:ground&&return :($name=ground!($builder,$(QuoteNode(name))))
        return :($name=$attach($builder,$call,$(QuoteNode(name))))
    elseif expression.head===:call&&expression.args[1]===:observe
        arguments=Any[expression.args[2:end]...]
        if !isempty(arguments)&&arguments[1] isa Expr&&arguments[1].head===:parameters
            return Expr(:call,:observe!,arguments[1],builder,arguments[2:end]...)
        end
        return Expr(:call,:observe!,builder,arguments...)
    elseif expression.head===:call&&expression.args[1]===:initial_voltage
        return Expr(:call,set_initial,builder,expression.args[2:end]...)
    elseif expression.head===:call
        return :($attach($builder,$expression))
    elseif expression.head===:block
        return Expr(:block,map(item->_design_macro_rewrite(item,builder),expression.args)...)
    elseif expression.head in (:for,:while)
        return Expr(expression.head,expression.args[1],_design_macro_rewrite(expression.args[2],builder))
    elseif expression.head===:if
        return Expr(:if,expression.args[1],map(item->_design_macro_rewrite(item,builder),expression.args[2:end])...)
    elseif expression.head===:let
        return Expr(:let,expression.args[1:end-1]...,_design_macro_rewrite(expression.args[end],builder))
    end
    expression
end

macro circuit(signature,block)
    parsed=signature isa Symbol ? Expr(:call,signature) : signature
    parsed isa Expr&&parsed.head===:call||error("@circuit requires a function-like signature")
    ports=Symbol[]
    for argument in parsed.args[2:end]
        argument isa Expr&&argument.head===:parameters&&continue
        port=argument isa Symbol ? argument : argument isa Expr&&argument.head===:(::) ? argument.args[1] : nothing
        port isa Symbol&&push!(ports,port)
    end
    isempty(ports)||return var"@subcircuit"(__source__,__module__,signature,block)
    name=parsed.args[1]; builder=gensym(:builder); rewritten=_design_macro_rewrite(block,builder)
    body=quote
        $builder=CircuitBuilder($(QuoteNode(name)))
        $rewritten
        finish($builder)
    end
    esc(Expr(:function,parsed,body))
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
    if under === nothing || isempty(String(under))
        for (primitive_index, primitive) in enumerate(design.root_ir.primitives)
            primitive_kind = typeof(primitive.kernel).parameters[1]
            kind !== nothing && primitive_kind != kind && continue
            path = DevicePath([(_name(design.names, primitive.name), nothing)])
            push!(output, (instance=nothing, path, kind=primitive_kind))
            length(output) >= limit && return output
        end
    end
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
    for (primitive_index, primitive) in enumerate(design.root_ir.primitives)
        _name(design.names, primitive.name) == target &&
            return ResolvedElement(:device, DevicePath(path.segments), nothing, primitive_index)
    end
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
