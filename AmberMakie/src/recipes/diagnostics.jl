function operatingpointplot(
        position, result::Amber.SimulationResult;
        query = "", kind = nothing, kwargs...
    )
    view = operatingpointview(result; query, kind)
    slot = _position(position); layout = Makie.GridLayout(slot)
    node_names = getproperty.(view.nodes, :name)
    node_values = getproperty.(view.nodes, :voltage)
    node_axis = Makie.Axis(
        layout[1, 1]; xlabel = "Node", ylabel = "Voltage (V)",
        xticks = (collect(eachindex(node_names)), node_names)
    )
    node_plot = Makie.barplot!(
        node_axis, collect(eachindex(node_values)), node_values;
        color = _AMBER_COLORS.output, kwargs...
    )

    powered = filter(row -> row.power !== nothing, view.devices)
    device_names = getproperty.(powered, :name)
    device_values = Float64[row.power for row in powered]
    device_axis = Makie.Axis(
        layout[2, 1]; xlabel = "Device", ylabel = "Power (W)",
        xticks = (collect(eachindex(device_names)), device_names)
    )
    device_plot = isempty(device_values) ? nothing :
        Makie.barplot!(
            device_axis, collect(eachindex(device_values)), device_values;
            color = ifelse.(device_values .>= 0, _AMBER_COLORS.nominal, _AMBER_COLORS.input)
        )
    isempty(device_values) && Makie.text!(
        device_axis, 0.5, 0.5;
        text = "No device power values available", space = :relative, align = (:center, :center),
        color = :gray45
    )
    return PlotHandle(
        layout,
        (operatingpoint = node_axis, nodes = node_axis, devices = device_axis),
        (operatingpoint = node_plot, nodes = node_plot, devices = device_plot), view
    )
end

function _diagnostic_group_text(grouped)
    isempty(grouped) && return "No validity warnings"
    sections = String[]
    for name in sort!(collect(keys(grouped)))
        push!(sections, "$(name)\n" * join(("  • " * warning for warning in grouped[name]), "\n"))
    end
    return join(sections, "\n\n")
end

function diagnosticplot(position, result; kwargs...)
    grouped = diagnosticgroups(result)
    slot = _position(position); layout = Makie.GridLayout(slot)
    warning_text = _diagnostic_group_text(grouped.groups)
    warning_label = Makie.Label(
        layout[1, 1], warning_text;
        justification = :left, halign = :left, valign = :top,
        color = isempty(grouped.warnings) ? :gray40 : _AMBER_COLORS.warning, kwargs...
    )
    device_lines = String[]
    for name in sort!(String.(collect(keys(grouped.devices))))
        fields = grouped.devices[name]
        rendered = fields isa NamedTuple ?
            join(("$(key)=$(value)" for (key, value) in pairs(fields)), ", ") : string(fields)
        push!(device_lines, "$(name): $(rendered)")
    end
    device_text = isempty(device_lines) ? "No device validity records" : join(device_lines, "\n")
    device_label = Makie.Label(
        layout[2, 1], device_text;
        justification = :left, halign = :left, valign = :top, color = :gray35
    )
    return PlotHandle(
        layout, NamedTuple(),
        (diagnostics = warning_label, device_validity = device_label), grouped
    )
end

function safeoperatingareaplot(
        position, result::Amber.SimulationResult;
        device, voltage, limits = (;), kwargs...
    )
    voltage_values = voltage isa AbstractVector ? Float64.(real.(voltage)) :
        Float64.(real.(Amber.trace(result, voltage)))
    current_values = Float64.(real.(Amber.current(result, device)))
    length(voltage_values) == length(current_values) ||
        throw(DimensionMismatch("SOA voltage and current traces differ in length"))
    v = abs.(voltage_values); i = abs.(current_values); p = v .* i
    max_voltage = Float64(get(limits, :max_voltage, Inf))
    max_current = Float64(get(limits, :max_current, Inf))
    max_power = Float64(get(limits, :max_power, Inf))
    all(>(0), filter(isfinite, [max_voltage, max_current, max_power])) ||
        throw(ArgumentError("finite SOA limits must be positive"))
    violations = findall(
        index -> v[index] > max_voltage || i[index] > max_current ||
            p[index] > max_power, eachindex(v)
    )
    slot = _position(position); axis = Makie.Axis(
        slot;
        xlabel = "|Device voltage| (V)", ylabel = "|Device current| (A)",
        xscale = log10, yscale = log10, title = "Safe operating area · $(device)"
    )
    floor_value = eps(Float64)
    trajectory = Makie.lines!(axis, max.(v, floor_value), max.(i, floor_value); kwargs...)
    violation_plot = isempty(violations) ? nothing : Makie.scatter!(
            axis,
            max.(v[violations], floor_value), max.(i[violations], floor_value);
            color = _AMBER_COLORS.invalid, marker = :x, markersize = 10
        )
    isfinite(max_voltage) && Makie.vlines!(
        axis, [max_voltage];
        color = _AMBER_COLORS.warning, linestyle = :dash
    )
    isfinite(max_current) && Makie.hlines!(
        axis, [max_current];
        color = _AMBER_COLORS.warning, linestyle = :dash
    )
    power_boundary = nothing
    if isfinite(max_power)
        positive_v = filter(>(0), v)
        domain = isempty(positive_v) ? [floor_value, 1.0] :
            exp.(
                range(
                    log(max(minimum(positive_v), floor_value)),
                    log(max(maximum(positive_v), floor_value * 10)); length = 200
                )
            )
        power_boundary = Makie.lines!(
            axis, domain, max_power ./ domain;
            color = _AMBER_COLORS.warning, linestyle = :dot
        )
    end
    return PlotHandle(
        slot, (soa = axis,),
        (trajectory = trajectory, violations = violation_plot, power_boundary),
        (
            device = String(device), voltage = v, current = i, power = p, limits = (;
                max_voltage, max_current, max_power,
            ), violations,
        )
    )
end

function _average_trace(axis, values)
    length(values) == 1 && return Float64(real(only(values)))
    duration = last(axis) - first(axis)
    duration > 0 || throw(ArgumentError("power averaging interval must be positive"))
    return Float64(real(_trapezoid(axis, values) / duration))
end

function powerdashboard(
        position, result::Amber.SimulationResult;
        devices = nothing, output = nothing, kwargs...
    )
    available = String[
        string(device.path) for device in
            Amber.devices(result.compiled.design; limit = typemax(Int))
    ]
    selected = devices === nothing ? available : String.(collect(devices))
    isempty(selected) && throw(ArgumentError("power dashboard requires devices"))
    powers = Pair{String, Float64}[]
    for name in selected
        value = try
            _average_trace(result.axis, Amber.power(result, name))
        catch
            continue
        end
        push!(powers, name => value)
    end
    isempty(powers) && throw(ArgumentError("selected devices expose no power observables"))
    labels, values = first.(powers), last.(powers)
    supplied = -sum(min(value, 0.0) for value in values)
    absorbed = sum(max(value, 0.0) for value in values)
    output_power = output === nothing ? nothing :
        _average_trace(result.axis, Amber.power(result, String(output)))
    efficiency = output_power === nothing || iszero(supplied) ? nothing :
        max(output_power, 0.0) / supplied
    slot = _position(position); layout = Makie.GridLayout(slot)
    axis = Makie.Axis(
        layout[1, 1]; xlabel = "Average power (W)", ylabel = "Device",
        yticks = (collect(eachindex(labels)), labels)
    )
    colors = ifelse.(values .>= 0, _AMBER_COLORS.nominal, _AMBER_COLORS.input)
    plot = Makie.barplot!(
        axis, collect(eachindex(values)), values;
        direction = :x, color = colors, kwargs...
    )
    card = "Supplied: $(engineering(supplied; unit = "W"))   Absorbed: $(engineering(absorbed; unit = "W"))" *
        (efficiency === nothing ? "" : "   Efficiency: $(round(100efficiency; digits = 2))%")
    Makie.Label(layout[2, 1], card; halign = :left)
    return PlotHandle(
        layout, (power = axis,), (power = plot,),
        (
            labels = labels, values = values, supplied = supplied, absorbed = absorbed,
            output_power = output_power, efficiency = efficiency,
        )
    )
end
