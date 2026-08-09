const _CIRCUIT_SCHEMA = "amber-circuit"
const _CIRCUIT_SCHEMA_VERSION = 3

struct CircuitSerializationError <: Exception
    message::String
end
Base.showerror(io::IO,error::CircuitSerializationError)=print(io,error.message)

const _SERIALIZABLE_STRUCTS = Dict{String,Any}(
    String(nameof(type)) => type for type in (
        Step, Sine, Pulse, ThinFilm, SMD0603, C0G, DebyeBranches,
        JunctionDiode, GummelPoonBJT, Level1MOSFET, BehavioralOpAmp,
        VoltageControlledSwitch, EventSwitch, SmoothSwitch,
        IdealResistor, IdealCapacitor, MatchedGroup, Differential,
    )
)

_stable_sort_key(value) = sprint(show, value)

_encode_value(::Nothing) = Dict("type" => "nothing")
_encode_value(value::Bool) = Dict("type" => "bool", "value" => value)
_encode_value(value::Integer) = Dict("type" => "integer", "value" => string(value), "unsigned" => value isa Unsigned)
_encode_value(value::AbstractFloat) = Dict("type" => "float", "value" => Float64(value))
_encode_value(value::Complex) = Dict("type" => "complex", "real" => Float64(real(value)), "imag" => Float64(imag(value)))
_encode_value(value::AbstractString) = Dict("type" => "string", "value" => String(value))
_encode_value(value::Symbol) = Dict("type" => "symbol", "value" => String(value))
_encode_value(value::Tuple) = Dict("type" => "tuple", "items" => [_encode_value(item) for item in value])
_encode_value(value::AbstractVector) = Dict("type" => "vector", "items" => [_encode_value(item) for item in value])
_encode_value(value::NamedTuple) = Dict("type" => "named_tuple", "entries" => [
    Dict("key" => String(key), "value" => _encode_value(item)) for (key, item) in sort!(collect(pairs(value)); by=x -> String(first(x)))
])
_encode_value(value::AbstractDict) = Dict("type" => "dict", "entries" => [
    Dict("key" => _encode_value(key), "value" => _encode_value(item))
    for (key, item) in sort!(collect(pairs(value)); by=x -> _stable_sort_key(first(x)))
])
function _encode_value(value)
    type_name = String(nameof(typeof(value)))
    haskey(_SERIALIZABLE_STRUCTS, type_name) || throw(ArgumentError("cannot serialize value of type $(typeof(value)) in a circuit parameter"))
    fields = [Dict("key" => String(key), "value" => _encode_value(getfield(value, key))) for key in fieldnames(typeof(value))]
    Dict("type" => "struct", "name" => type_name, "fields" => fields)
end

function _decode_value(encoded,nodes,components,depth::Int=0,max_depth::Int=64)
    depth<=max_depth||throw(CircuitSerializationError("serialized value exceeds the nesting-depth limit"))
    kind = encoded["type"]
    kind == "nothing" && return nothing
    kind in ("bool", "float", "string") && return encoded["value"]
    kind == "complex" && return ComplexF64(encoded["real"],encoded["imag"])
    if kind=="integer"
        value=encoded["value"]
        value isa Integer&&return value
        return get(encoded,"unsigned",false) ? parse(UInt64,value) : parse(Int64,value)
    end
    kind == "symbol" && return Symbol(encoded["value"])
    if kind == "tuple"
        return Tuple(_decode_value(item,nodes,components,depth+1,max_depth) for item in encoded["items"])
    elseif kind == "vector"
        return [_decode_value(item,nodes,components,depth+1,max_depth) for item in encoded["items"]]
    elseif kind == "named_tuple"
        pairs = [Symbol(entry["key"]) => _decode_value(entry["value"],nodes,components,depth+1,max_depth) for entry in encoded["entries"]]
        return (; pairs...)
    elseif kind == "dict"
        return Dict(_decode_value(entry["key"],nodes,components,depth+1,max_depth) => _decode_value(entry["value"],nodes,components,depth+1,max_depth) for entry in encoded["entries"])
    elseif kind == "struct"
        name = encoded["name"]
        type = get(_SERIALIZABLE_STRUCTS, name, nothing)
        type === nothing && throw(ArgumentError("serialized circuit uses unsupported value type $(name)"))
        values = Dict(Symbol(field["key"]) => _decode_value(field["value"],nodes,components,depth+1,max_depth) for field in encoded["fields"])
        if type in (IdealResistor, IdealCapacitor)
            return type(values[:value])
        elseif type === Differential
            return Differential(values[:positive], values[:negative])
        elseif type in (ThinFilm, SMD0603, C0G, DebyeBranches, JunctionDiode,
                GummelPoonBJT, Level1MOSFET, BehavioralOpAmp,
                VoltageControlledSwitch, EventSwitch, SmoothSwitch)
            return type(values[:data])
        end
        return type(; values...)
    end
    throw(ArgumentError("unknown serialized value type $(kind)"))
end

function deserialize_circuit(text::AbstractString;max_bytes::Integer=16*1024*1024,max_nodes::Integer=1_000_000,max_components::Integer=1_000_000,max_depth::Integer=64)
    sizeof(text)<=max_bytes||throw(CircuitSerializationError("serialized circuit exceeds the byte limit"))
    try
        header = TOML.parse(text)
        get(header, "schema", nothing) == _CIRCUIT_SCHEMA || throw(ArgumentError("not an Amber circuit serialization"))
        version = get(header, "schema_version", nothing)
        version == _CIRCUIT_SCHEMA_VERSION || throw(CircuitSerializationError(
            "unsupported Amber circuit schema version $(version); only immutable hierarchical schema 3 is supported"))
        _deserialize_design(header; max_nodes, max_components, max_depth)
    catch error
        error isa CircuitSerializationError&&rethrow()
        throw(CircuitSerializationError("invalid Amber circuit serialization: $(sprint(showerror,error))"))
    end
end

load_circuit(path::AbstractString) = deserialize_circuit(read(path, String))

_hex128(value::UInt128) = string(value; base=16, pad=32)
_parse128(value::AbstractString) = parse(UInt128, value; base=16)

function _hierarchy_encode(value)
    value isa LocalNetReference && return Dict("type" => "local_net_reference", "net" => Int(value.id))
    value isa LocalPrimitiveReference && return Dict("type" => "local_primitive_reference", "primitive" => Int(value.id))
    value isa ParameterReference && return Dict("type" => "parameter_reference", "name_id" => Int(value.name))
    value isa ParameterLiteral && return Dict("type" => "parameter_literal", "value" => _hierarchy_encode(value.value))
    value isa ParameterCall && return Dict("type" => "parameter_call", "operation" => Int(value.operation), "arguments" => _hierarchy_encode.(value.arguments))
    value isa NamedTuple && return Dict("type" => "hierarchy_named_tuple", "entries" => [
        Dict("key" => String(key), "value" => _hierarchy_encode(item)) for (key, item) in pairs(value)
    ])
    value isa Tuple && return Dict("type" => "hierarchy_tuple", "items" => _hierarchy_encode.(collect(value)))
    value isa AbstractVector && return Dict("type" => "hierarchy_vector", "items" => _hierarchy_encode.(value))
    _encode_value(value)
end

function _hierarchy_decode(value, max_depth::Int, depth::Int=0)
    depth <= max_depth || throw(CircuitSerializationError("serialized value exceeds the nesting-depth limit"))
    kind = value["type"]
    kind == "local_net_reference" && return LocalNetReference(Int32(value["net"]))
    kind == "local_primitive_reference" && return LocalPrimitiveReference(Int32(value["primitive"]))
    kind == "parameter_reference" && return ParameterReference(NameId(value["name_id"]))
    kind == "parameter_literal" && return ParameterLiteral(_hierarchy_decode(value["value"], max_depth, depth + 1))
    kind == "parameter_call" && return ParameterCall(UInt8(value["operation"]), AbstractParameterExpression[_hierarchy_decode(item, max_depth, depth + 1) for item in value["arguments"]])
    if kind == "hierarchy_named_tuple"
        entries = value["entries"]
        names = Tuple(Symbol(entry["key"]) for entry in entries)
        return NamedTuple{names}(Tuple(_hierarchy_decode(entry["value"], max_depth, depth + 1) for entry in entries))
    end
    kind == "hierarchy_tuple" && return Tuple(_hierarchy_decode(item, max_depth, depth + 1) for item in value["items"])
    kind == "hierarchy_vector" && return [_hierarchy_decode(item, max_depth, depth + 1) for item in value["items"]]
    _decode_value(value, Dict{Int,AbstractNode}(), Dict{Any,Any}(), depth, max_depth)
end

function _segment_snapshot(segment::NameSegment, names::NameTable)
    Dict("base" => _name(names, segment.base), "index" => _hierarchy_encode(segment.index))
end

function _segment_restore(snapshot, names::_NameBuilder, max_depth)
    NameSegment(_intern!(names, snapshot["base"]), _hierarchy_decode(snapshot["index"], max_depth))
end

function _observation_reference_snapshot(value)
    value isa BuilderNet && return Dict("type"=>"net","id"=>Int(value.id))
    value isa BuilderPrimitive && return Dict("type"=>"primitive","id"=>Int(value.id))
    value isa Symbol && return Dict("type"=>"symbol","value"=>String(value))
    value isa AbstractString && return Dict("type"=>"string","value"=>String(value))
    value === nothing && return Dict("type"=>"nothing")
    throw(ArgumentError("unsupported hierarchical observation reference $(typeof(value))"))
end

function _observation_snapshot(observation)
    value = observation.value
    if value isa BuilderNet || value isa BuilderPrimitive
        return Dict("name"=>observation.name===nothing ? "" : String(observation.name),
            "kind"=>"raw", "target"=>_observation_reference_snapshot(value),
            "extra"=>_observation_reference_snapshot(nothing))
    end
    value isa Observable || throw(ArgumentError("hierarchical observations must be Observable values or builder handles"))
    Dict("name" => observation.name === nothing ? "" : String(observation.name),
        "kind"=>String(value.kind), "target"=>_observation_reference_snapshot(value.target),
        "extra"=>_observation_reference_snapshot(value.extra))
end

function _observation_reference_restore(snapshot,names,primitives,owner,generation)
    kind=snapshot["type"]
    kind=="nothing"&&return nothing
    kind=="symbol"&&return Symbol(snapshot["value"])
    kind=="string"&&return String(snapshot["value"])
    id=Int32(snapshot["id"])
    kind=="net"&&return BuilderNet(owner,generation,id,names[Int(id)])
    kind=="primitive"&&begin
        1<=id<=length(primitives)||throw(CircuitSerializationError("observation refers to an unknown primitive"))
        return BuilderPrimitive(owner,generation,id,primitives[Int(id)].name)
    end
    throw(CircuitSerializationError("unknown observation reference type $(kind)"))
end

function _primitive_snapshot(primitive, body::TemplateIR, names::NameTable)
    Dict(
        "kind" => String(typeof(primitive.kernel).parameters[1]),
        "name" => _name(names, primitive.name),
        "terminals" => Int.(body.terminal_data[primitive.terminals]),
        "parameters" => _hierarchy_encode(primitive.parameters),
    )
end

function _body_snapshot(body::TemplateIR, names::NameTable)
    Dict(
        "nets" => [_segment_snapshot(segment, names) for segment in body.net_names],
        "ground_net" => Int(body.ground_net),
        "primitives" => [_primitive_snapshot(primitive, body, names) for primitive in body.primitives],
        "observations" => [_observation_snapshot(observation) for observation in body.observations],
    )
end

function _template_snapshot(template::SubcircuitTemplate)
    Dict(
        "name" => _name(template.names, template.name),
        "ports" => [Dict("name" => _name(template.names, port.name), "required" => port.required, "reference" => port.reference) for port in template.ports],
        "parameters" => [Dict("name" => _name(template.names, parameter.name), "default" => _hierarchy_encode(parameter.default), "structural" => parameter.structural) for parameter in template.parameters],
        "body" => _body_snapshot(template.body, template.names),
        "structural_fingerprint" => _hex128(template.structural_fingerprint),
    )
end

"""Return deterministic schema-3 hierarchical data without flattening the design."""
function circuit_snapshot(design::CircuitDesign)
    Dict{String,Any}(
        "schema" => _CIRCUIT_SCHEMA,
        "schema_version" => 3,
        "name" => _name(design.names, design.name),
        "templates" => [_template_snapshot(template) for template in design.templates.templates],
        "root_body" => _body_snapshot(design.root_ir, design.names),
        "instances" => [Dict(
            "template" => Int(record.template), "parent" => Int(record.parent),
            "name" => _segment_snapshot(record.name, design.names),
            "connections" => Int.(design.root.connection_data[Int(record.connections.start):Int(record.connections.start) + Int(record.connections.length) - 1]),
            "parameters" => [_hierarchy_encode(item) for item in design.root.parameter_data[Int(record.parameters.start):Int(record.parameters.start) + Int(record.parameters.length) - 1]],
            "partition_hint" => Int(record.partition_hint),
        ) for record in design.root.records],
        "metadata" => _hierarchy_encode(design.metadata.values),
        "structural_fingerprint" => _hex128(design.structural_fingerprint),
        "parameter_fingerprint" => _hex128(design.parameter_fingerprint),
    )
end

function serialize_circuit(design::CircuitDesign)
    io = IOBuffer()
    TOML.print(io, circuit_snapshot(design); sorted=true)
    String(take!(io))
end

function _restore_body(snapshot, names::_NameBuilder, owner::UInt64, generation::UInt32, max_depth)
    net_names = [_segment_restore(item, names, max_depth) for item in snapshot["nets"]]
    terminal_data = Int32[]
    primitives = Any[]
    for primitive_snapshot in snapshot["primitives"]
        terminals = Int32.(primitive_snapshot["terminals"])
        start = Int32(length(terminal_data) + 1); append!(terminal_data, terminals)
        stop = start + Int32(length(terminals) - 1)
        parameters = _hierarchy_decode(primitive_snapshot["parameters"], max_depth)
        name = _intern!(names, primitive_snapshot["name"])
        kind = Symbol(primitive_snapshot["kind"])
        push!(primitives, PrimitiveSpec(Val(kind), start:stop, parameters, name))
    end
    observations = Any[]
    for observation in get(snapshot, "observations", Any[])
        target=_observation_reference_restore(observation["target"],net_names,primitives,owner,generation)
        extra=_observation_reference_restore(observation["extra"],net_names,primitives,owner,generation)
        value=observation["kind"]=="raw" ? target : Observable(Symbol(observation["kind"]),target,extra)
        push!(observations, (name=isempty(observation["name"]) ? nothing : observation["name"], value=value))
    end
    TemplateIR(net_names, Int32(snapshot["ground_net"]), terminal_data, primitives, observations)
end

function _restore_template(snapshot, max_depth)
    names = _NameBuilder(); name = _intern!(names, snapshot["name"])
    ports = PortSpec[]
    for port in snapshot["ports"]
        push!(ports, PortSpec(_intern!(names, port["name"]), port["required"], port["reference"]))
    end
    parameters = ParameterSpec[]
    for parameter in snapshot["parameters"]
        push!(parameters, ParameterSpec(_intern!(names, parameter["name"]), _hierarchy_decode(parameter["default"], max_depth), parameter["structural"]))
    end
    body = _restore_body(snapshot["body"], names, UInt64(0), UInt32(0), max_depth)
    SubcircuitTemplate(name, ports, parameters, body, _parse128(snapshot["structural_fingerprint"]), NameTable(copy(names.strings)))
end

function _deserialize_design(snapshot; max_nodes, max_components, max_depth)
    templates_snapshot = get(snapshot, "templates", Any[])
    templates = [_restore_template(item, max_depth) for item in templates_snapshot]
    names = _NameBuilder(); name = _intern!(names, snapshot["name"])
    root_body = _restore_body(snapshot["root_body"], names, UInt64(0), UInt32(0), max_depth)
    length(root_body.net_names) <= max_nodes || throw(CircuitSerializationError("serialized design exceeds the node limit"))
    records = InstanceRecord[]; connections = Int32[]; parameters = Any[]; path_nodes = _PathNode[]
    primitive_count = length(root_body.primitives)
    for instance in snapshot["instances"]
        template_id = TemplateId(instance["template"])
        1 <= Int(template_id) <= length(templates) || throw(CircuitSerializationError("instance refers to an unknown template"))
        connection_start = UInt32(length(connections) + 1); instance_connections = Int32.(instance["connections"]); append!(connections, instance_connections)
        parameter_start = UInt32(length(parameters) + 1); instance_parameters = [_hierarchy_decode(item, max_depth) for item in instance["parameters"]]; append!(parameters, instance_parameters)
        segment = _segment_restore(instance["name"], names, max_depth)
        parent = InstanceId(instance["parent"])
        parent.value < UInt32(length(records) + 1) || throw(CircuitSerializationError("instance parent must precede its child"))
        parent_path = parent.value == 0 ? PathId(0) : records[Int(parent)].path
        push!(path_nodes, _PathNode(parent_path, segment))
        push!(records, InstanceRecord(template_id, parent, segment,
            ConnectionRange(connection_start, UInt16(length(instance_connections))),
            ParameterRange(parameter_start, UInt16(length(instance_parameters))),
            PartitionHint(instance["partition_hint"]), PathId(length(path_nodes))))
        primitive_count += length(templates[Int(template_id)].body.primitives)
    end
    primitive_count <= max_components || throw(CircuitSerializationError("serialized design exceeds the component limit"))
    metadata = Dict{String,Any}(_hierarchy_decode(snapshot["metadata"], max_depth))
    CircuitDesign(name, TemplateRegistry(templates), InstanceGraph(records, connections, parameters),
        ObservationSet(copy(root_body.observations)), DesignMetadata(metadata),
        _parse128(snapshot["structural_fingerprint"]), _parse128(snapshot["parameter_fingerprint"]),
        NameTable(copy(names.strings)), root_body, PathTrie(path_nodes))
end

save_circuit(path::AbstractString, design::CircuitDesign) = (open(io -> write(io, serialize_circuit(design)), path, "w"); path)
