const LIGHT_PALETTE = (ink = "#192632", wire = "#465663", value = "#50616D",
    net = "#176562", block = "#F1F5F6", background = "#FFFFFF")
const DARK_PALETTE = (ink = "#E6EDF3", wire = "#A5B4C3", value = "#B4C1CD",
    net = "#70D7C7", block = "#202B37", background = "#111923")
const WIRE_WIDTH = 1.45
const SYMBOL_WIDTH = 2.0
const PIXELS_PER_UNIT = 72

function _segments(drawing)
    segments = [(net, a, b) for (net, points) in drawing.routes
        for (a, b) in zip(points, @view points[2:end])]
    for component in drawing.components, index in _visible_pins(component)
        net = component.nets[index]
        pin = _pin(component, index)
        push!(segments, (net, _transform(component.placement, pin.edge),
            _transform(component.placement, pin.tip)))
    end
    return segments
end

_on_segment(point, a, b) = all(i -> min(a[i], b[i]) <= point[i] <= max(a[i], b[i]), 1:2)

function _component_box(component)
    width, height = _halfwidth(component), _halfheight(component)
    a = _transform(component.placement, (-width, -height))
    b = _transform(component.placement, (width, height))
    return (min.(a, b), max.(a, b))
end

function _validate_wiring(drawing)
    segments = _segments(drawing)
    boxes = [(component.name, _component_box(component)...) for component in drawing.components]
    for (index, (name, low, high)) in enumerate(boxes)
        for (other, bottom, top) in @view boxes[1:index-1]
            all(i -> max(low[i], bottom[i]) < min(high[i], top[i]), 1:2) &&
                throw(ArgumentError("component bodies `$name` and `$other` overlap"))
        end
        for (_, a, b) in segments
            all(i -> low[i] < max(a[i], b[i]) && min(a[i], b[i]) < high[i], 1:2) &&
                throw(ArgumentError("a conductor passes through the body of `$name`"))
        end
    end
    for (index, (net, a, b)) in enumerate(segments), (other, c, d) in @view segments[1:index-1]
        net == other && continue
        if all(i -> max(min(a[i], b[i]), min(c[i], d[i])) <=
                min(max(a[i], b[i]), max(c[i], d[i])), 1:2)
            throw(ArgumentError("wires for `$(drawing.nets[net])` and `$(drawing.nets[other])` touch or cross"))
        end
    end
end

function _ground_paths((x, y))
    stem = ((x, y), (x, y - 0.23))
    bars = map(((0.23, 0.21), (0.31, 0.135), (0.39, 0.06))) do (offset, width)
        ((x - width, y - offset), (x + width, y - offset))
    end
    return stem, bars
end

function _validate_ground_marker(drawing, point, segments)
    stem, bars = _ground_paths(point)
    for path in (stem, bars...)
        box = _path_box(path)
        for component in drawing.components
            _boxes_overlap(box, _component_box(component)) &&
                throw(ArgumentError("ground marker at $point overlaps the body of `$(component.name)`"))
        end
        for (net, a, b) in segments
            net == drawing.ground && continue
            _boxes_overlap(box, _path_box((a, b))) &&
                throw(ArgumentError("ground marker at $point overlaps a conductor for `$(drawing.nets[net])`"))
        end
    end
end

function _junctions(drawing)
    isempty(drawing.routes) && return Coordinate[]
    segments = _segments(drawing)
    junctions = Coordinate[]
    candidates = Set((net, point) for (net, points) in drawing.routes for point in points)
    horizontal = [(net, a, b) for (net, a, b) in segments if a[2] == b[2]]
    vertical = [(net, a, b) for (net, a, b) in segments if a[1] == b[1]]
    for (net, a, b) in horizontal, (other, c, d) in vertical
        if net == other && min(a[1], b[1]) <= c[1] <= max(a[1], b[1]) &&
                min(c[2], d[2]) <= a[2] <= max(c[2], d[2])
            push!(candidates, (net, (c[1], a[2])))
        end
    end
    for (net, point) in candidates
        directions = Set{Coordinate}()
        for (other, a, b) in segments
            net == other || continue
            all(i -> min(a[i], b[i]) <= point[i] <= max(a[i], b[i]), 1:2) || continue
            for end_point in (a, b)
                end_point == point && continue
                push!(directions, sign.(end_point .- point))
            end
        end
        length(directions) >= 3 && push!(junctions, point)
    end
    return sort!(junctions)
end

function _arrow!(stroke, from, to; head = 0.12)
    dx, dy = to .- from
    ux, uy = (dx, dy) ./ hypot(dx, dy)
    back = to .- head .* (ux, uy)
    wing = (head / 2) .* (-uy, ux)
    stroke([from, to])
    stroke([back .+ wing, to, back .- wing])
end

function _sign!(stroke, (x, y), positive; size = 0.055, rotated = false)
    if positive || !rotated
        stroke([(x - size, y), (x + size, y)])
    end
    if positive || rotated
        stroke([(x, y - size), (x, y + size)])
    end
end

function _diamond((x, y), radius)
    return [(x, y + radius), (x + radius, y), (x, y - radius),
        (x - radius, y), (x, y + radius)]
end

function _controlled_source!(stroke, conductor, mark, kind)
    if kind in (:vccs, :vcvs)
        x = 0.22
        conductor([(x, 0.38), (x, 0.65)])
        conductor([(x, -0.38), (x, -0.65)])
        stroke(_diamond((x, 0.0), 0.38))
        for side in (-1, 1)
            y = side * 0.25
            conductor([(-0.65, y), (-0.44, y)])
            mark((-0.32, y), side == 1)
        end
        if kind === :vcvs
            mark((x, 0.14), true)
            mark((x, -0.14), false)
        else
            _arrow!(stroke, (x, 0.20), (x, -0.20))
        end
    else
        stroke(_diamond((0.0, 0.0), 0.39))
        conductor([(-0.60, 0), (-0.39, 0)])
        conductor([(0.39, 0), (0.60, 0)])
        if kind === :ccvs
            mark((-0.15, 0), true)
            mark((0.15, 0), false)
        else
            _arrow!(stroke, (-0.20, 0), (0.20, 0))
        end
    end
end

function _symbol!(stroke, conductor, component)
    kind = component.symbol
    mark(point, positive; size = 0.055) = _sign!(stroke, point, positive;
        size, rotated = component.placement.rotation % 180 != 0)
    if _is_mosfet(component)
        pmos = component.kind === :pmos
        bubble = pmos && kind === :mos_logic
        conductor([(-0.65, 0), (bubble ? -0.43 : -0.25, 0)])
        bubble && stroke([(-0.34 + 0.09cos(t), 0.09sin(t)) for t in range(0, 2π; length = 33)])
        stroke([(-0.25, -0.40), (-0.25, 0.40)])
        if kind === :mos_logic
            stroke([(-0.08, -0.38), (-0.08, 0.38)])
        else
            for y in (-0.32, 0.0, 0.32)
                stroke([(-0.08, y - 0.096), (-0.08, y + 0.096)])
            end
        end
        for side in (-1, 1)
            conductor([(-0.08, side * 0.32), (0.25, side * 0.32), (0.25, side * 0.65)])
        end
        if kind === :mos_body_tied
            side = pmos ? 1 : -1
            conductor([(-0.08, 0), (0.25, 0), (0.25, side * 0.32)])
            tip, tail = pmos ? (0.19, 0.02) : (0.02, 0.19)
            stroke([(tail, -0.072), (tip, 0), (tail, 0.072)])
        elseif kind !== :mos_logic
            conductor([(-0.08, 0), (0.65, 0)])
            tip, tail = pmos ? (0.19, 0.02) : (0.02, 0.19)
            stroke([(tail, -0.075), (tip, 0), (tail, 0.075)])
        end
    elseif kind === :opamp
        stroke([(-0.42, 0.59), (0.59, 0), (-0.42, -0.59), (-0.42, 0.59)])
        conductor([(0.59, 0), (0.65, 0)])
        for side in (-1, 1)
            y = side * 0.27
            conductor([(-0.65, y), (-0.42, y)])
            conductor([(-0.22, side * 0.47), (-0.22, side * 0.65)])
            mark((-0.29, y), side == 1)
        end
    elseif kind === :npn
        conductor([(-0.65, 0), (-0.16, 0)])
        stroke([(-0.16, -0.41), (-0.16, 0.41)])
        stroke([(-0.16, 0.18), (0.30, 0.47)])
        _arrow!(stroke, (-0.16, -0.18), (0.30, -0.47); head = 0.19)
        for side in (-1, 1)
            conductor([(0.30, side * 0.47), (0.30, side * 0.65)])
        end
    elseif kind === :switch
        for side in (-1, 1)
            x = side * 0.30
            conductor([(side * 0.65, 0), (x + side * 0.047, 0)])
            stroke([(x + 0.047cos(t), 0.047sin(t)) for t in range(0, 2π; length = 24)])
            conductor([(side * 0.24, -0.65), (side * 0.24, -0.43)])
            mark((side * 0.24, -0.33), side == -1)
        end
        stroke([(-0.26, 0.025), (0.25, 0.30)])
        for y in (-0.46, -0.30, -0.14)
            stroke([(0, y), (0, y + 0.07)])
        end
    elseif kind in (:vccs, :vcvs, :cccs, :ccvs)
        _controlled_source!(stroke, conductor, mark, kind)
    elseif kind in (:iec_resistor, :conductance, :variable_resistor)
        stroke([(-0.41, 0.15), (0.41, 0.15), (0.41, -0.15), (-0.41, -0.15), (-0.41, 0.15)])
        for side in (-1, 1)
            conductor([(side * 0.41, 0), (side * 0.60, 0)])
        end
        kind === :variable_resistor && _arrow!(stroke, (-0.22, -0.32), (0.22, 0.32))
    elseif kind === :resistor
        conductor([(-0.60, 0), (-0.42, 0)])
        stroke([(-0.42, 0), [(x, isodd(i) ? 0.13 : -0.13)
            for (i, x) in enumerate(range(-0.35, 0.35; length = 6))]..., (0.42, 0)])
        conductor([(0.42, 0), (0.60, 0)])
    elseif kind === :polarized_capacitor
        conductor([(-0.60, 0), (-0.10, 0)])
        conductor([(0.10, 0), (0.60, 0)])
        stroke([(-0.10, -0.27), (-0.10, 0.27)])
        stroke([(0.10 + 1.1y^2, y) for y in range(-0.27, 0.27; length = 25)])
        mark((-0.27, 0.22), true)
    elseif kind in (:capacitor, :variable_capacitor)
        for side in (-1, 1)
            conductor([(side * 0.60, 0), (side * 0.10, 0)])
            stroke([(side * 0.10, -0.27), (side * 0.10, 0.27)])
        end
        kind === :variable_capacitor && _arrow!(stroke, (-0.28, -0.32), (0.28, 0.32))
    elseif kind === :inductor
        for center in (-0.45, -0.15, 0.15, 0.45)
            stroke([(center + 0.15cos(t), 0.23sin(t)) for t in range(π, 0; length = 24)])
        end
    elseif kind === :diode || kind in DIODE_VARIANTS
        conductor([(-0.60, 0), (-0.23, 0)])
        stroke([(-0.23, -0.25), (-0.23, 0.25), (0.23, 0), (-0.23, -0.25)])
        if kind === :zener
            stroke([(0.32, -0.32), (0.23, -0.26), (0.23, 0.26), (0.14, 0.32)])
        elseif kind === :schottky
            stroke([(0.30, -0.18), (0.30, -0.26), (0.23, -0.26), (0.23, 0.26),
                (0.16, 0.26), (0.16, 0.18)])
        else
            stroke([(0.23, -0.26), (0.23, 0.26)])
        end
        if kind in (:led, :photodiode)
            for x in (-0.23, -0.04)
                inside, outside = (x, 0.33), (x + 0.15, 0.55)
                kind === :led ? _arrow!(stroke, inside, outside; head = 0.085) :
                    _arrow!(stroke, outside, inside; head = 0.085)
            end
        end
        conductor([(0.23, 0), (0.60, 0)])
    else
        stroke([(0.39cos(t), 0.39sin(t)) for t in range(0, 2π; length = 65)])
        conductor([(-0.60, 0), (-0.39, 0)])
        conductor([(0.39, 0), (0.60, 0)])
        if kind === :voltage_source
            mark((-0.19, 0), true; size = 0.08)
            mark((0.19, 0), false; size = 0.08)
        elseif kind === :sine_source
            stroke([(x, 0.13sinpi(x / 0.24)) for x in range(-0.24, 0.24; length = 33)])
        else
            stroke([(-0.23, 0), (0.23, 0)])
            stroke([(0.09, -0.11), (0.23, 0), (0.09, 0.11)])
        end
    end
end

function _label_box(label, font)
    glyph_box = CM.Makie.text_bb(String(label.value), font, Float32(label.size))
    width, height = glyph_box.widths[1:2] ./ PIXELS_PER_UNIT
    horizontal, vertical = label.align
    x = horizontal === :left ? 0 : horizontal === :right ? -width : -width / 2
    y = vertical === :bottom ? 0 : vertical === :top ? -height : -height / 2
    rotation = get(label, :rotation, 0.0)
    low, high = if iszero(rotation)
        ((x, y), (x + width, y + height))
    elseif rotation > 0
        ((-y - height, x), (-y, x + width))
    else
        ((y, -x - width), (y + height, -x))
    end
    return (low .+ label.at, high .+ label.at)
end

function _path_box(points; padding = 0.035)
    xmin, xmax = extrema(first, points)
    ymin, ymax = extrema(last, points)
    return ((xmin - padding, ymin - padding), (xmax + padding, ymax + padding))
end

_shift_box((low, high), offset) = (low .+ offset, high .+ offset)

function _boxes_overlap((low, high), (other_low, other_high); gap = 0.025)
    return all(i -> low[i] < other_high[i] + gap && other_low[i] < high[i] + gap, 1:2)
end

function _label_positions(groups, obstacles)
    fonts = CM.Makie.theme(:fonts)
    faces = Dict(name => CM.Makie.to_font(fonts, name) for name in (:regular, :bold))
    labels = NamedTuple[]
    for (group, direction) in groups
        boxes = [_label_box(label, faces[label.font]) for label in group]
        offset = (0.0, 0.0)
        if direction != (0, 0)
            tangent = (-direction[2], direction[1])
            attempt = 0
            while true
                # Look near the intended anchor before moving farther out.
                forward = 0.10 * div(attempt, 5)
                sideways = (0.0, 0.14, -0.14, 0.28, -0.28)[mod1(attempt + 1, 5)]
                offset = forward .* direction .+ sideways .* tangent
                any(box -> any(obstacle -> _boxes_overlap(_shift_box(box, offset), obstacle),
                    obstacles), boxes) || break
                attempt += 1
            end
        end
        append!(obstacles, (_shift_box(box, offset) for box in boxes))
        append!(labels, (merge(label, (at = label.at .+ offset,)) for label in group))
    end
    return labels
end

function _check_label_clearance(labels, boxes)
    for (index, box) in enumerate(boxes)
        for other in 1:index-1
            _boxes_overlap(box, boxes[other]; gap = 0.0) || continue
            first_label, second_label = labels[other].value, labels[index].value
            throw(ArgumentError("schematic labels `$first_label` and `$second_label` overlap"))
        end
    end
end

# A strip between protected intervals can only contain straight orthogonal
# wire runs. Keep a gutter and translate everything beyond it by the same amount.
function _compact_axis(protected, axis)
    intervals = sort!([(low[axis], high[axis]) for (low, high) in protected])
    cuts = Tuple{Float64, Float64}[]
    edge = first(intervals)[2]
    for (low, high) in intervals
        gap = low - edge
        gap > 1.2 && push!(cuts, (low, gap - 1.2))
        edge = max(edge, high)
    end
    return cuts
end

function _compact_point(point, cuts)
    return ntuple(2) do axis
        coordinate = point[axis]
        coordinate - sum(width for (start, width) in cuts[axis] if start <= coordinate; init = 0.0)
    end
end

"""
Render a schematic with the `:light` or `:dark` palette. Set `compact=true`
to shorten oversized gaps or `check_layout=true` to check wiring and label clearance.
"""
function figure(drawing::Schematic; theme::Symbol = :light, compact::Bool = false,
                check_layout::Bool = false)
    palette = theme === :light ? LIGHT_PALETTE : theme === :dark ? DARK_PALETTE :
        throw(ArgumentError("expected theme=:light or theme=:dark"))
    check_layout && _validate_wiring(drawing)
    conductors = Vector{Coordinate}[]
    outlines = Vector{Coordinate}[]
    blocks = Vector{Coordinate}[]
    groups = Tuple{Vector{NamedTuple}, Coordinate}[]
    fixed = NamedTuple[]
    protected = Tuple{Coordinate, Coordinate}[]
    for (_, points) in drawing.routes
        push!(conductors, compact ? copy(points) : points)
    end
    for component in drawing.components
        first_outline = length(outlines) + 1
        first_conductor = length(conductors) + 1
        transform(point) = _transform(component.placement, point)
        stroke(points) = push!(outlines, transform.(points))
        conductor(points) = push!(conductors, transform.(points))
        width, height = _halfwidth(component), _halfheight(component)
        if _has_symbol(component)
            _symbol!(stroke, conductor, component)
        else
            corners = [(-width, -height), (width, -height), (width, height), (-width, height)]
            push!(blocks, transform.(corners))
            stroke([corners; first(corners)])
        end
        cx, cy = component.placement.center
        rotated = component.placement.rotation % 180 != 0
        _is_mosfet(component) && !rotated && (cx -= 0.29)
        caption = split(component.label, '\n')
        extent = if !_has_symbol(component)
            rotated ? height : _halfheight(component)
        elseif _is_mosfet(component)
            0.51
        elseif component.symbol in (:npn, :opamp, :vcvs, :vccs)
            1.29
        elseif component.symbol === :switch
            0.69
        elseif component.symbol in (:led, :photodiode, :variable_capacitor, :variable_resistor)
            0.48
        elseif component.symbol === :resistor
            0.13
        elseif component.kind in (:voltage_source, :current_source)
            0.39
        else
            0.27
        end
        gap = extent + 0.15
        caption_labels = NamedTuple[]
        for (line, content) in enumerate(caption)
            baseline = 0.22 * (length(caption) - line)
            at = rotated ? (cx + gap, cy + baseline - 0.11 * (length(caption) - 1)) :
                (cx, cy + gap + baseline)
            align = rotated ? (:left, :center) : (:center, :bottom)
            isempty(content) && continue
            push!(caption_labels, (at, value = content, align, size = line == 1 ? 14 : 12,
                color = line == 1 ? palette.ink : palette.value, font = line == 1 ? :bold : :regular))
        end
        push!(groups, (caption_labels, rotated ? (1, 0) : (0, 1)))
        for index in _visible_pins(component)
            net = component.nets[index]
            pin = _pin(component, index)
            conductor([pin.edge, pin.tip])
            if !_has_symbol(component)
                at = transform(pin.edge .- (pin.side * 0.12, 0))
                rotation = rotated ? (component.placement.rotation == 90 ? π / 2 : -π / 2) : 0.0
                left_aligned = rotated ? pin.side < 0 : at[1] < cx
                align = (left_aligned ? :left : :right, :center)
                push!(fixed, (at = at, value = component.pins[index], align, rotation,
                    size = 11, color = palette.value, font = :regular))
            end
            net in drawing.unlabelled && continue
            tip, edge = transform(pin.tip), transform(pin.edge)
            outward = sign.(tip .- edge)
            at = tip .+ 0.12 .* outward
            align = outward[1] == 0 ? (:center, outward[2] > 0 ? :bottom : :top) :
                (outward[1] > 0 ? :left : :right, :center)
            label = (at, value = drawing.nets[net], align, size = 12, color = palette.net, font = :regular)
            push!(groups, ([label], outward))
        end
        if compact
            paths = Iterators.flatten((@view(outlines[first_outline:end]),
                @view(conductors[first_conductor:end])))
            points = collect(Iterators.flatten(paths))
            push!(protected, isempty(points) ? _component_box(component) : _path_box(points))
        end
    end

    marker_segments = isempty(drawing.markers) ? () : _segments(drawing)
    for (net, (x, y)) in drawing.markers
        if net == drawing.ground
            stem, bars = _ground_paths((x, y))
            push!(conductors, collect(stem))
            append!(outlines, collect.(bars))
            compact && push!(protected, _path_box(collect(Iterators.flatten((stem, bars...)))))
        else
            on_horizontal = any(marker_segments) do (id, a, b)
                id == net && a[2] == b[2] && _on_segment((x, y), a, b)
            end
            at = on_horizontal ? (x, y + 0.14) : (x - 0.14, y)
            align = on_horizontal ? (:center, :bottom) : (:right, :center)
            label = (at, value = drawing.nets[net], align, size = 13, color = palette.net, font = :bold)
            pushfirst!(groups, ([label], on_horizontal ? (0, 1) : (-1, 0)))
        end
    end

    junctions = unique!(append!(_junctions(drawing),
        [point for (net, point) in drawing.markers if net == drawing.ground]))
    taps = [point for (net, point) in drawing.markers if net != drawing.ground]
    obstacles = [_path_box(path) for path in Iterators.flatten((outlines, blocks))]
    for path in conductors, (a, b) in zip(path, @view path[2:end])
        push!(obstacles, _path_box((a, b)))
    end
    for point in Iterators.flatten((junctions, taps))
        push!(obstacles, _path_box((point,); padding = 0.045))
    end
    pushfirst!(groups, (fixed, (0, 0)))
    first_label = length(obstacles) + 1
    labels = _label_positions(groups, obstacles)
    label_boxes = @view obstacles[first_label:end]
    check_layout && _check_label_clearance(labels, label_boxes)
    if compact
        append!(protected, label_boxes)
        for (_, points) in drawing.routes, point in points
            push!(protected, _path_box((point,)))
        end
        for point in Iterators.flatten((junctions, taps))
            push!(protected, _path_box((point,); padding = 0.045))
        end
        cuts = ntuple(axis -> _compact_axis(protected, axis), 2)
        shift(point) = _compact_point(point, cuts)
        for paths in (blocks, conductors, outlines), path in paths
            map!(shift, path, path)
        end
        map!(shift, junctions, junctions)
        map!(shift, taps, taps)
        map!(box -> map(shift, box), obstacles, obstacles)
        labels = [merge(label, (at = shift(label.at),)) for label in labels]
    end
    bounds = collect(Iterators.flatten(obstacles))
    xmin, xmax = extrema(first, bounds) .+ (-0.36, 0.36)
    ymin, ymax = extrema(last, bounds) .+ (-0.36, 0.36)
    size = ceil.(Int, PIXELS_PER_UNIT .* (xmax - xmin, ymax - ymin))
    fig = CM.Figure(; size, figure_padding = 0, backgroundcolor = palette.background)
    ax = CM.Axis(fig[1, 1]; aspect = CM.DataAspect(), backgroundcolor = palette.background)
    CM.hidedecorations!(ax)
    CM.hidespines!(ax)
    CM.limits!(ax, xmin, xmax, ymin, ymax)
    for block in blocks
        CM.poly!(ax, CM.Point2d.(block); color = palette.block, strokewidth = 0)
    end
    for (paths, color, linewidth) in ((conductors, palette.wire, WIRE_WIDTH),
                                     (outlines, palette.ink, SYMBOL_WIDTH))
        for path in paths
            CM.lines!(ax, CM.Point2d.(path); color, linewidth,
                linecap = :round, joinstyle = :round)
        end
    end
    isempty(junctions) || CM.scatter!(ax, CM.Point2d.(junctions); color = palette.ink, markersize = 4.5)
    isempty(taps) || CM.scatter!(ax, CM.Point2d.(taps); color = palette.net, markersize = 5.5)
    for label in labels
        CM.text!(ax, label.at...; text = label.value, fontsize = label.size,
            align = label.align, color = label.color, font = label.font,
            rotation = get(label, :rotation, 0.0))
    end
    return fig
end

"""Save an Amber schematic to SVG, PDF or PNG and return the output path."""
function save_schematic(path::AbstractString, drawing::Schematic; theme::Symbol = :light,
                        compact::Bool = false, check_layout::Bool = false, kwargs...)
    lowercase(splitext(path)[2]) in (".svg", ".pdf", ".png") ||
        throw(ArgumentError("expected a .svg, .pdf, or .png output path"))
    CM.save(path, figure(drawing; theme, compact, check_layout); kwargs...)
    return path
end
