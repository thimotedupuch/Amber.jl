const _CIRCUIT_SCHEMA = "amber-circuit"
const _CIRCUIT_SCHEMA_VERSION = 1
const _CIRCUIT_MIGRATIONS = Dict{Int,Function}()

struct CircuitSerializationError <: Exception
    message::String
end
Base.showerror(io::IO,error::CircuitSerializationError)=print(io,error.message)

const _SERIALIZABLE_STRUCTS = Dict{String,DataType}(
    String(nameof(type)) => type for type in (
        Step, Sine, Pulse, ThinFilm, SMD0603, C0G, DebyeBranches,
        JunctionDiode, GummelPoonBJT, BehavioralOpAmp,
        VoltageControlledSwitch, EventSwitch, SmoothSwitch,
        IdealResistor, IdealCapacitor, MatchedGroup, Differential,
    )
)

_stable_sort_key(value) = sprint(show, value)

_encode_value(::Nothing) = Dict("type" => "nothing")
_encode_value(value::Bool) = Dict("type" => "bool", "value" => value)
_encode_value(value::Integer) = Dict("type" => "integer", "value" => string(value), "unsigned" => value isa Unsigned)
_encode_value(value::AbstractFloat) = Dict("type" => "float", "value" => Float64(value))
_encode_value(value::AbstractString) = Dict("type" => "string", "value" => String(value))
_encode_value(value::Symbol) = Dict("type" => "symbol", "value" => String(value))
_encode_value(value::AbstractNode) = Dict("type" => "node", "id" => value.id)
_encode_value(value::Component) = Dict("type" => "component", "name" => String(value.name))
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
    if kind=="integer"
        value=encoded["value"]
        value isa Integer&&return value
        return get(encoded,"unsigned",false) ? parse(UInt64,value) : parse(Int64,value)
    end
    kind == "symbol" && return Symbol(encoded["value"])
    if kind == "node"
        id = Int(encoded["id"])
        haskey(nodes, id) || throw(ArgumentError("serialized circuit refers to unknown node id $(id)"))
        return nodes[id]
    elseif kind == "component"
        name = Symbol(encoded["name"])
        haskey(components, name) || throw(ArgumentError("serialized circuit refers to unknown component $(name)"))
        return components[name]
    elseif kind == "tuple"
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
        elseif fieldnames(type) == (:data,)
            return type(values[:data])
        end
        return type(; values...)
    end
    throw(ArgumentError("unknown serialized value type $(kind)"))
end

function _encode_observable(observable::Observable)
    Dict("kind" => String(observable.kind), "target" => _encode_value(observable.target), "extra" => _encode_value(observable.extra))
end

function _decode_observable(encoded,nodes,components,max_depth=64)
    Observable(Symbol(encoded["kind"]),_decode_value(encoded["target"],nodes,components,0,max_depth),_decode_value(encoded["extra"],nodes,components,0,max_depth))
end

"""Return the versioned, session-independent representation of a circuit."""
function circuit_snapshot(circuit::Circuit)
    named = get(circuit.metadata, :named_observations, Dict{Symbol,Any}())
    ports = get(circuit.metadata, :ports, Dict{Symbol,Any}())
    metadata = Dict(key => value for (key, value) in circuit.metadata if key ∉ (:named_observations, :ports))
    all(observation -> observation isa Observable, circuit.observations) || throw(ArgumentError("circuit contains an unsupported non-Observable observation"))
    Dict{String,Any}(
        "schema" => _CIRCUIT_SCHEMA,
        "schema_version" => _CIRCUIT_SCHEMA_VERSION,
        "name" => String(circuit.name),
        "nodes" => [Dict("id" => node.id, "name" => String(node.name), "ground" => node isa Ground) for node in circuit.nodes],
        "components" => [Dict(
            "kind" => String(component.kind),
            "name" => String(component.name),
            "terminals" => [node.id for node in component.terminals],
            "parameters" => _encode_value(component.parameters),
        ) for component in circuit.components],
        "observations" => [_encode_observable(observable) for observable in circuit.observations],
        "named_observations" => [Dict("name" => String(name), "observable" => _encode_observable(observable)) for (name, observable) in sort!(collect(pairs(named)); by=x -> String(first(x)))],
        "ports" => [Dict("name" => String(name), "node" => terminal.id) for (name, terminal) in sort!(collect(pairs(ports)); by=x -> String(first(x))) if terminal isa AbstractNode],
        "metadata" => _encode_value(metadata),
    )
end

"""Serialize a circuit to deterministic, versioned TOML text."""
function serialize_circuit(circuit::Circuit)
    io = IOBuffer()
    TOML.print(io, circuit_snapshot(circuit); sorted=true)
    String(take!(io))
end

"""Reconstruct a circuit from `serialize_circuit` TOML text."""
function _deserialize_circuit(text::AbstractString;max_nodes,max_components,max_depth)
    snapshot = try
        TOML.parse(text)
    catch error
        throw(CircuitSerializationError("invalid Amber circuit serialization: $(sprint(showerror, error))"))
    end
    get(snapshot, "schema", nothing) == _CIRCUIT_SCHEMA || throw(ArgumentError("not an Amber circuit serialization"))
    version = get(snapshot, "schema_version", nothing)
    while version != _CIRCUIT_SCHEMA_VERSION&&haskey(_CIRCUIT_MIGRATIONS,version)
        snapshot=_CIRCUIT_MIGRATIONS[version](snapshot); version=snapshot["schema_version"]
    end
    version == _CIRCUIT_SCHEMA_VERSION || throw(CircuitSerializationError("unsupported Amber circuit schema version $(version)"))
    nodes_snapshot=get(snapshot,"nodes",nothing); components_snapshot=get(snapshot,"components",nothing)
    nodes_snapshot isa AbstractVector||throw(CircuitSerializationError("serialized circuit nodes must be an array"))
    components_snapshot isa AbstractVector||throw(CircuitSerializationError("serialized circuit components must be an array"))
    length(nodes_snapshot)<=max_nodes||throw(CircuitSerializationError("serialized circuit exceeds the node limit"))
    length(components_snapshot)<=max_components||throw(CircuitSerializationError("serialized circuit exceeds the component limit"))
    circuit = Circuit(Symbol(snapshot["name"]))
    nodes = Dict{Int,AbstractNode}()
    for encoded in snapshot["nodes"]
        id = Int(encoded["id"]); name = Symbol(encoded["name"])
        node = encoded["ground"] ? Ground(circuit, id, name) : Node(circuit, id, name)
        haskey(nodes, id) && throw(ArgumentError("duplicate node id $(id) in serialized circuit"))
        nodes[id] = node; push!(circuit.nodes, node)
    end
    components = Dict{Symbol,Component}()
    for encoded in snapshot["components"]
        name = Symbol(encoded["name"])
        terminals = AbstractNode[nodes[Int(id)] for id in encoded["terminals"]]
        parameters = Dict{Symbol,Any}(_decode_value(encoded["parameters"],nodes,components,0,max_depth))
        component = Component(Symbol(encoded["kind"]), terminals, parameters, name)
        haskey(components, name) && throw(ArgumentError("duplicate component name $(name) in serialized circuit"))
        components[name] = component; push!(circuit.components, component)
    end
    append!(circuit.observations, [_decode_observable(item,nodes,components,max_depth) for item in get(snapshot, "observations", Any[])])
    circuit.metadata[:named_observations] = Dict(Symbol(item["name"]) => _decode_observable(item["observable"],nodes,components,max_depth) for item in get(snapshot, "named_observations", Any[]))
    circuit.metadata[:ports] = Dict(Symbol(item["name"]) => nodes[Int(item["node"])] for item in get(snapshot, "ports", Any[]))
    merge!(circuit.metadata, Dict{Symbol,Any}(_decode_value(get(snapshot,"metadata",_encode_value(Dict{Symbol,Any}())),nodes,components,0,max_depth)))
    circuit
end

function deserialize_circuit(text::AbstractString;max_bytes::Integer=16*1024*1024,max_nodes::Integer=1_000_000,max_components::Integer=1_000_000,max_depth::Integer=64)
    sizeof(text)<=max_bytes||throw(CircuitSerializationError("serialized circuit exceeds the byte limit"))
    try
        _deserialize_circuit(text;max_nodes,max_components,max_depth)
    catch error
        error isa CircuitSerializationError&&rethrow()
        throw(CircuitSerializationError("invalid Amber circuit serialization: $(sprint(showerror,error))"))
    end
end

function save_circuit(path::AbstractString, circuit::Circuit)
    open(path, "w") do io
        write(io, serialize_circuit(circuit))
    end
    path
end

load_circuit(path::AbstractString) = deserialize_circuit(read(path, String))
