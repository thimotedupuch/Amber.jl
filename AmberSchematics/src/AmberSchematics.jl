module AmberSchematics

import Amber
import CairoMakie as CM

export schematic, connectivity, anchor, Placement, Wire, figure, save_schematic

const Coordinate = NTuple{2, Float64}
const Terminal = Tuple{String, Int}
const MOSFETS = (:nmos, :pmos)
const MOS_VARIANTS = (:mos_body_tied, :mos_logic)
const DIODE_VARIANTS = (:zener, :schottky, :led, :photodiode)
const CAPACITOR_VARIANTS = (:polarized_capacitor, :variable_capacitor)
const RESISTOR_VARIANTS = (:iec_resistor, :variable_resistor)
const TWO_PIN_SYMBOLS = (:resistor, :conductance, :capacitor, :inductor, :diode,
    :voltage_source, :sine_source, :current_source, :ccvs, :cccs, DIODE_VARIANTS...,
    CAPACITOR_VARIANTS..., RESISTOR_VARIANTS...)
const NAMED_PINS = Dict(
    :diode => ["A", "K"], :voltage_source => ["+", "−"],
    :current_source => ["+", "−"], :ccvs => ["+", "−"], :cccs => ["+", "−"],
    :npn => ["C", "B", "E"], :nmos => ["D", "G", "S", "B"],
    :pmos => ["D", "G", "S", "B"], :opamp => ["IN+", "IN−", "OUT", "V+", "V−"],
    :switch => ["A", "B", "CTRL+", "CTRL−"],
    :vccs => ["CTRL+", "CTRL−", "OUT+", "OUT−"],
    :vcvs => ["CTRL+", "CTRL−", "OUT+", "OUT−"],
)
const MULTI_PIN_SYMBOLS = (MOSFETS..., MOS_VARIANTS..., :npn, :opamp, :switch, :vcvs, :vccs)

function _select_symbol(kind, requested)
    requested isa Symbol || throw(ArgumentError("symbol overrides must be Symbols"))
    compatible = kind === :diode ? DIODE_VARIANTS :
        kind === :capacitor ? CAPACITOR_VARIANTS :
        kind in (:resistor, :conductance) ? RESISTOR_VARIANTS :
        kind in MOSFETS ? MOS_VARIANTS :
        kind === :voltage_source ? (:sine_source,) : ()
    requested == kind || requested in compatible ||
        throw(ArgumentError("symbol `$requested` is incompatible with Amber device kind `$kind`"))
    return requested
end

"""Place a component at `(x, y)` in schematic units, with counterclockwise rotation."""
struct Placement
    center::Coordinate
    rotation::Int
    function Placement(x::Real, y::Real; rotation::Integer = 0)
        all(isfinite, (Float64(x), Float64(y))) || throw(ArgumentError("placement must be finite"))
        rotation % 90 == 0 || throw(ArgumentError("rotation must be a multiple of 90 degrees"))
        return new((x, y), mod(rotation, 360))
    end
end

"""Connect two Amber terminals, identified by `(device, terminal_index)`, through optional bends."""
struct Wire
    from::Terminal
    to::Terminal
    via::Vector{Coordinate}
    function Wire(from, to; via = ())
        return new((string(from[1]), Int(from[2])), (string(to[1]), Int(to[2])),
            Coordinate[(x, y) for (x, y) in via])
    end
end

struct Component
    name::String
    kind::Symbol
    symbol::Symbol
    label::String
    nets::Vector{Int}
    pins::Vector{String}
    placement::Placement
end

struct Schematic
    components::Vector{Component}
    nets::Dict{Int, String}
    ground::Int
    routes::Vector{Tuple{Int, Vector{Coordinate}}}
    unlabelled::Set{Int}
    markers::Vector{Tuple{Int, Coordinate}}
end

_keyed(values) = Dict(string(name) => value for (name, value) in pairs(values))

"""
    schematic(design; placements=Dict(), labels=Dict(), wires=Wire[], net_markers=Dict(), symbols=Dict(), columns=3)

Build a deterministic top-level view of a finished Amber circuit. Placement and
label overrides are keyed by device or instance path. Unrouted connections are
shown with matching net labels. `net_markers` maps Amber net names to points
on their conductors. Ground markers use the earth symbol. Use `symbols` to
select compatible visual variants by component name.
"""
function schematic(design::Amber.CircuitDesign; placements = Dict(), labels = Dict(),
                   wires = Wire[], net_markers = Dict(), symbols = Dict(), columns::Integer = 3)
    columns > 0 || throw(ArgumentError("columns must be positive"))
    placements, labels = _keyed(placements), _keyed(labels)
    net_markers, symbols = _keyed(net_markers), _keyed(symbols)
    body = design.root_ir
    nets = Dict(Int(net.id) => string(net.path) for net in Amber.nets(design; limit = typemax(Int)))
    ground = Int(body.ground_net)
    specs = NamedTuple[]
    for primitive in body.primitives
        name = Amber._name(design.names, primitive.name)
        kind = typeof(primitive.kernel).parameters[1]
        terminals = body.terminal_data[primitive.terminals]
        pins = get(NAMED_PINS, kind) do
            string.(eachindex(terminals))
        end
        symbol = _select_symbol(kind, get(symbols, name, kind))
        if symbol in MOS_VARIANTS && terminals[3] != terminals[4]
            throw(ArgumentError("symbol `$symbol` requires source and bulk on the same net for `$name`"))
        end
        label = symbol in TWO_PIN_SYMBOLS || symbol in MULTI_PIN_SYMBOLS ? name :
            name * " · " * replace(string(kind), '_' => ' ')
        push!(specs, (; name, kind, symbol, terminals, pins, label))
    end
    for instance in instances(design; limit = typemax(Int))
        record = design.root.records[Int(instance.id)]
        Int(record.parent) == 0 || continue
        template = design.templates.templates[Int(record.template)]
        name = string(instance.path)
        pins = [Amber._name(template.names, port.name) for port in template.ports]
        offset = Int(record.connections.start)
        terminals = design.root.connection_data[offset:(offset + length(pins) - 1)]
        label = name * " · " * Amber._name(template.names, template.name)
        symbol = _select_symbol(:subcircuit, get(symbols, name, :subcircuit))
        push!(specs, (; name, kind = :subcircuit, symbol, terminals, pins, label))
    end
    isempty(specs) && throw(ArgumentError("the circuit has no components to draw"))
    names = Set(spec.name for spec in specs)
    length(names) == length(specs) || throw(ArgumentError("component names must be unique"))
    for name in union(keys(placements), keys(labels), keys(symbols))
        name in names || throw(ArgumentError("unknown component `$name`"))
    end
    maxnet = maximum(length, values(nets); init = 0)
    captions = [split(get(labels, spec.name, spec.label), '\n') for spec in specs]
    maxlabel = maximum(length, Iterators.flatten(captions))
    maxpins = maximum(spec -> length(spec.pins), specs)
    maxpin = maximum((length(pin) for spec in specs for pin in spec.pins); init = 0)
    spacing_x = max(5.0 + 0.32maxnet + 0.28maxpin, 1.0 + 0.23maxlabel)
    spacing_y = max(3.4, 1.8 + 0.42cld(maxpins, 2)) + 0.3 * (maximum(length, captions) - 1)
    components = Component[]
    for (index, spec) in enumerate(specs)
        row, column = divrem(index - 1, columns)
        placement = get(placements, spec.name, Placement(column * spacing_x, -row * spacing_y))
        push!(components, Component(spec.name, spec.kind, spec.symbol, get(labels, spec.name, spec.label),
            spec.terminals, spec.pins, placement))
    end
    routes = Tuple{Int, Vector{Coordinate}}[]
    drawing = Schematic(components, nets, ground, routes, Set{Int}(), Tuple{Int, Coordinate}[])
    links = Dict{Terminal, Vector{Terminal}}()
    for wire in wires
        start, stop = _terminal(drawing, wire.from), _terminal(drawing, wire.to)
        start.net == stop.net || throw(ArgumentError("wire joins different Amber nets: $(wire.from) and $(wire.to)"))
        points = Coordinate[start.at, wire.via..., stop.at]
        all(point -> all(isfinite, point), points) || throw(ArgumentError("wire coordinates must be finite"))
        for (a, b) in zip(points, @view points[2:end])
            a != b && (a[1] == b[1] || a[2] == b[2]) ||
                throw(ArgumentError("wire segments must be nonzero and horizontal or vertical"))
        end
        push!(routes, (start.net, points))
        from = _visible_terminal(drawing, wire.from)
        to = _visible_terminal(drawing, wire.to)
        push!(get!(links, from, Terminal[]), to)
        push!(get!(links, to, Terminal[]), from)
    end
    if !isempty(routes)
        bynet = Dict{Int, Vector{Terminal}}()
        for component in components, index in _visible_pins(component)
            net = component.nets[index]
            push!(get!(bynet, net, Terminal[]), (component.name, index))
        end
        for (net, terminals) in bynet
            visited = Set{Terminal}()
            pending = [first(terminals)]
            while !isempty(pending)
                terminal = pop!(pending)
                terminal in visited && continue
                push!(visited, terminal)
                append!(pending, get(links, terminal, ()))
            end
            length(visited) == length(terminals) && length(terminals) > 1 &&
                (net != ground || haskey(net_markers, nets[net])) &&
                push!(drawing.unlabelled, net)
        end
    end
    (!isempty(routes) || !isempty(placements)) && _validate_wiring(drawing)
    segments = isempty(net_markers) ? () : _segments(drawing)
    for (name, value) in pairs(net_markers)
        point = convert(Coordinate, value)
        net = findfirst(==(string(name)), nets)
        net === nothing && throw(ArgumentError("unknown net `$name`"))
        any(segment -> segment[1] == net && _on_segment(point, segment[2], segment[3]), segments) ||
            throw(ArgumentError("marker for `$name` must be on one of its conductors"))
        push!(drawing.markers, (net, point))
    end
    sort!(drawing.markers)
    return drawing
end

_is_mosfet(component) = component.kind in MOSFETS
_visible_pins(component) = component.symbol in MOS_VARIANTS ? (1:3) : eachindex(component.pins)
_has_symbol(component) = component.symbol in MULTI_PIN_SYMBOLS ||
    (component.symbol in TWO_PIN_SYMBOLS && length(component.pins) == 2)
_halfwidth(component) = component.symbol in MULTI_PIN_SYMBOLS ? 0.65 : _has_symbol(component) ? 0.60 :
    max(0.85, 0.15maximum(length, component.pins; init = 0) + 0.22)
_halfheight(component) = component.symbol in MULTI_PIN_SYMBOLS ? 0.65 :
    _has_symbol(component) ? 0.55 : max(0.40, 0.21cld(length(component.pins), 2))

# Each anchor is (body edge, wire tip), in Amber terminal order.
_side(side, y = 0.0) = ((0.65side, y), (1.05side, y))
_vertical(side, x) = ((x, 0.65side), (x, 1.05side))
const SPECIAL_ANCHORS = Dict(
    :nmos => (_vertical(1, 0.25), _side(-1), _vertical(-1, 0.25), _side(1)),
    :pmos => (_vertical(-1, 0.25), _side(-1), _vertical(1, 0.25), _side(1)),
    :npn => (_vertical(1, 0.30), _side(-1), _vertical(-1, 0.30)),
    :opamp => (_side(-1, 0.27), _side(-1, -0.27), _side(1),
               _vertical(1, -0.22), _vertical(-1, -0.22)),
    :switch => (_side(-1), _side(1), _vertical(-1, -0.24), _vertical(-1, 0.24)),
    :vcvs => (_side(-1, 0.25), _side(-1, -0.25), _vertical(1, 0.22), _vertical(-1, 0.22)),
    :vccs => (_side(-1, 0.25), _side(-1, -0.25), _vertical(1, 0.22), _vertical(-1, 0.22)),
)

function _transform(placement, (x, y))
    cx, cy = placement.center
    rotation = placement.rotation
    return (cx + cosd(rotation) * x - sind(rotation) * y,
            cy + sind(rotation) * x + cosd(rotation) * y)
end

function _pin(component, index)
    count = length(component.pins)
    index in 1:count || throw(ArgumentError("invalid terminal $index on $(component.name)"))
    style = _is_mosfet(component) ? component.kind : component.symbol
    if haskey(SPECIAL_ANCHORS, style)
        index = component.symbol in MOS_VARIANTS && index == 4 ? 3 : index
        edge, tip = SPECIAL_ANCHORS[style][index]
        return (; edge, tip)
    end
    left = cld(count, 2)
    side = index <= left ? -1 : 1
    position, total = side == -1 ? (index, left) : (index - left, count - left)
    y = 0.42 * ((total + 1) / 2 - position)
    x = side * _halfwidth(component)
    return (edge = (x, y), tip = (x + side * 0.45, y), side = side)
end

function _component_named(drawing, name)
    match = findfirst(component -> component.name == name, drawing.components)
    match === nothing && throw(ArgumentError("unknown component `$name`"))
    return drawing.components[match]
end

function _visible_terminal(drawing, (name, index))
    component = _component_named(drawing, name)
    return (name, component.symbol in MOS_VARIANTS && index == 4 ? 3 : index)
end

function _terminal(drawing, (name, index))
    component = _component_named(drawing, name)
    pin = _pin(component, index)
    return (at = _transform(component.placement, pin.tip), net = component.nets[index])
end

"""Return the world coordinate of an Amber terminal's wire anchor."""
anchor(drawing::Schematic, name, index::Integer) = _terminal(drawing, (string(name), index)).at

"""List terminal indices, pin names and Amber nets in deterministic component order."""
function connectivity(drawing::Schematic)
    return [(device = component.name, kind = component.kind, terminal = index, pin = pin,
        net = drawing.nets[component.nets[index]], ground = component.nets[index] == drawing.ground)
        for component in drawing.components for (index, pin) in enumerate(component.pins)]
end

include("render.jl")

end
