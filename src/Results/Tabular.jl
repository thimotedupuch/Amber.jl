"""
    result_table(result)

Return an allocation-owning vector of named tuples in plain Julia values. The
first column is `time` or `frequency`; remaining columns are node voltages.
This is the dependency-free tabular core consumed by optional Tables/Arrow
integrations.
"""
function result_table(result::SimulationResult)
    axis_name=result.analysis isa SmallSignal ? :frequency :
        result.analysis isa Union{Transient,TransientNoise} ? :time : :point
    design=result.compiled.design
    nodes=[_render_segment((_name(design.names,segment.base),segment.index))
        for (index,segment) in enumerate(design.root_ir.net_names) if index!=design.root_ir.ground_net]
    names=Tuple(vcat(axis_name,Symbol.(nodes)))
    columns=Any[result.axis]
    append!(columns,[voltage(result,node) for node in nodes])
    row_type=NamedTuple{names}
    [row_type(Tuple(column[index] for column in columns)) for index in eachindex(result.axis)]
end
