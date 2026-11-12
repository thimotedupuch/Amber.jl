"""
    result_table(result; signals=nothing)

Return an allocation-owning vector of named tuples with Unitful physical values. The
first column is `time`, `frequency`, or `point` (operating point); remaining
columns default to root node voltages. If a root node uses the axis name, the
axis column receives repeated `_axis` suffixes until its name is unique.
To select and label columns, pass a named
tuple of observables or named observations. Physical values carry SI units. Use `ustrip` when exporting numeric columns.

```julia
rows = result_table(result; signals=(output_V=voltage(:out),
    supply_A=current(:Source), supply_W=power(:Source)))
```

This is the dependency-free tabular core consumed by optional Tables/Arrow
integrations.
"""
function result_table(result::SimulationResult; signals = nothing)
    axis_name = result.analysis isa SmallSignal ? :frequency :
        result.analysis isa Union{Transient, TransientNoise} ? :time : :point
    design = result.compiled.design
    nodes = [
        _render_segment((_name(design.names, segment.base), segment.index))
            for (index, segment) in enumerate(design.root_ir.net_names) if index != design.root_ir.ground_net
    ]
    axis = result.analysis isa SmallSignal ? result.axis .* Unitful.Hz : result.analysis isa Union{Transient, TransientNoise} ? result.axis .* Unitful.s : result.axis
    columns = Any[axis]
    if signals === nothing
        while String(axis_name) in nodes
            axis_name = Symbol(axis_name, "_axis")
        end
        names = Tuple(vcat(axis_name, Symbol.(nodes)))
        append!(columns, [voltage(result, node) for node in nodes])
    else
        signals isa NamedTuple||throw(ArgumentError("signals must be a named tuple of observables or named observations"))
        axis_name in keys(signals)&&throw(ArgumentError("signal column names must not reuse the axis column $(axis_name)"))
        names = (axis_name, keys(signals)...)
        append!(columns, [trace(result, signal) for signal in values(signals)])
    end
    row_type = NamedTuple{names}
    return [row_type(Tuple(column[index] for column in columns)) for index in eachindex(result.axis)]
end
