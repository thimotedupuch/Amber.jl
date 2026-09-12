struct PlotHandle{L,A,P,V}
    layout::L
    axes::A
    plots::P
    view::V
end

mutable struct WorkbenchHandle{F,A,P,S,U,M,W,V,C}
    figure::F
    axes::A
    plots::P
    selection::S
    cursors::U
    measurements::M
    warnings::W
    provenance::V
    cleanup::C
    closed::Bool
end

function Base.close(handle::WorkbenchHandle)
    handle.closed && return nothing
    subscriptions = get(handle.measurements, :control_subscriptions, nothing)
    if subscriptions !== nothing
        foreach(Makie.off, subscriptions)
        empty!(subscriptions)
    end
    handle.cleanup()
    handle.closed = true
    nothing
end

function _plot_observable(value, attribute)
    direct = try getproperty(value, attribute) catch; nothing end
    direct === nothing || return direct
    attributes = try getproperty(value, :attributes) catch; nothing end
    attributes === nothing && return nothing
    try
        haskey(attributes, attribute) ? attributes[attribute] : nothing
    catch
        nothing
    end
end

function _trace_entries!(entries, value, prefix="")
    visible = _plot_observable(value, :visible)
    if visible !== nothing
        lowered = lowercase(prefix)
        any(token -> occursin(token, lowered),
            ("cursor", "critical", "highlight", "selected", "direction", "endpoint")) ||
            (entries[prefix] = value)
    elseif value isa NamedTuple || value isa AbstractDict
        for (name, child) in pairs(value)
            path = isempty(prefix) ? string(name) : string(prefix, ".", name)
            _trace_entries!(entries, child, path)
        end
    elseif value isa AbstractVector
        for (index, child) in pairs(value)
            _trace_entries!(entries, child, string(prefix, "[", index, "]"))
        end
    end
    entries
end

function _trace_entries(handle::WorkbenchHandle)
    entries = Dict{String,Any}()
    _trace_entries!(entries, handle.plots)
    entries
end

"""Show only the named workbench trace, as with the trace-legend isolation control."""
function isolatetrace!(handle::WorkbenchHandle, name)
    handle.closed && throw(ArgumentError("workbench is closed"))
    entries = _trace_entries(handle)
    target = String(name)
    haskey(entries, target) || throw(KeyError(name))
    for (label, plot) in entries
        _plot_observable(plot, :visible)[] = label == target
    end
    callback = get(handle.measurements, :trace_selection_callback, nothing)
    callback === nothing || callback(target)
    handle.measurements[:isolated_trace][] = target
    handle
end

"""Restore every semantic trace hidden through the workbench trace legend."""
function showalltraces!(handle::WorkbenchHandle)
    handle.closed && throw(ArgumentError("workbench is closed"))
    for plot in values(_trace_entries(handle))
        _plot_observable(plot, :visible)[] = true
    end
    callback = get(handle.measurements, :show_all_callback, nothing)
    callback === nothing || callback()
    isolated = get(handle.measurements, :isolated_trace, nothing)
    isolated === nothing || (isolated[] = nothing)
    handle
end

function toggletrace!(handle::WorkbenchHandle, name)
    handle.closed && throw(ArgumentError("workbench is closed"))
    entries = _trace_entries(handle)
    target = String(name)
    haskey(entries, target) || throw(KeyError(name))
    visible = _plot_observable(entries[target], :visible)
    visible[] = !visible[]
    handle
end

helptext(handle::WorkbenchHandle) = String(get(handle.measurements, :help,
    "Click a trace to position cursor A; Shift-click positions cursor B."))

function _contextualize!(handle::WorkbenchHandle; help=nothing)
    help === nothing || (handle.measurements[:help] = String(help))
    haskey(handle.measurements, :context_toolbar) && return handle
    entries = _trace_entries(handle)
    labels = sort!(collect(keys(entries)))
    isolated = Makie.Observable{Union{Nothing,String}}(nothing)
    help_visible = Makie.Observable(false)
    toolbar = Makie.GridLayout(handle.figure[0, 1:2])
    help_button = Makie.Button(toolbar[1, 1]; label="Help")
    show_button = Makie.Button(toolbar[1, 2]; label="Show all")
    legend_control = isempty(labels) ? nothing : Makie.Menu(toolbar[1, 3];
        options=vcat([("Trace legend · all", "")], [(label, label) for label in labels]),
        default=1)
    help_label = Makie.Label(toolbar[1, 4], Makie.lift(help_visible) do visible
        visible ? helptext(handle) : "H: help · A: show all"
    end; halign=:left, justification=:left)
    subscriptions = Any[]
    push!(subscriptions, Makie.on(help_button.clicks) do _
        help_visible[] = !help_visible[]
    end)
    push!(subscriptions, Makie.on(show_button.clicks) do _
        showalltraces!(handle)
    end)
    legend_control === nothing || push!(subscriptions,
        Makie.on(legend_control.selection) do selected
            selected === nothing || isempty(selected) ? showalltraces!(handle) :
                isolatetrace!(handle, selected)
        end)
    push!(subscriptions, Makie.on(Makie.events(handle.figure).keyboardbutton) do event
        event.action == Makie.Keyboard.press || return
        event.key == Makie.Keyboard.h && (help_visible[] = !help_visible[])
        event.key == Makie.Keyboard.a && showalltraces!(handle)
    end)
    handle.measurements[:isolated_trace] = isolated
    handle.measurements[:help_visible] = help_visible
    handle.measurements[:legend_entries] = labels
    handle.measurements[:legend_control] = legend_control
    handle.measurements[:context_toolbar] = toolbar
    handle.measurements[:control_subscriptions] = subscriptions
    handle
end

function selectsample!(handle::WorkbenchHandle, sample::Integer)
    handle.closed && throw(ArgumentError("workbench is closed"))
    selection = get(handle.measurements, :selected_sample, nothing)
    selection === nothing && throw(ArgumentError("workbench does not support sample selection"))
    sample_range = get(handle.measurements, :sample_range, nothing)
    sample_range === nothing || Int(sample) in sample_range || throw(BoundsError(sample_range, sample))
    selection[] = Int(sample)
    handle
end

function replay_sample!(handle::WorkbenchHandle; sample=nothing)
    handle.closed && throw(ArgumentError("workbench is closed"))
    replay = get(handle.measurements, :replay, nothing)
    replay === nothing && throw(ArgumentError(
        "workbench has no replay circuit; pass `circuit` when constructing it"))
    index = sample === nothing ? handle.measurements[:selected_sample][] : Int(sample)
    replay(index)
end

function selectcomponent!(handle::WorkbenchHandle, name)
    handle.closed && throw(ArgumentError("workbench is closed"))
    selected = get(handle.measurements, :selected, nothing)
    selected === nothing && throw(ArgumentError("workbench does not support component selection"))
    choices = get(handle.measurements, :selection_names, nothing)
    value = String(name)
    choices === nothing || value in choices || throw(KeyError(name))
    selected[] = value
    handle
end

function selectsignal!(handle::WorkbenchHandle, signal)
    handle.closed && throw(ArgumentError("workbench is closed"))
    selected = get(handle.measurements, :selected_signal, nothing)
    selected === nothing && throw(ArgumentError("workbench does not support signal selection"))
    choices = get(handle.measurements, :signal_choices, Any[])
    index = findfirst(choice -> isequal(choice, signal), choices)
    index === nothing && throw(KeyError(signal))
    control = get(handle.measurements, :signal_control, nothing)
    if control !== nothing && control.i_selected[] != index
        control.i_selected[] = index
    else
        selected[] = choices[index]
    end
    handle
end

_position(position) = position isa Makie.Figure ? position[1, 1] : position
