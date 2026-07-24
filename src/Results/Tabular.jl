"""
    result_table(result)

Return an allocation-owning vector of named tuples in plain Julia values. The
first column is `time` or `frequency`; remaining columns are node voltages.
This is the dependency-free tabular core consumed by optional Tables/Arrow
integrations.
"""
function result_table(result::SimulationResult)
    axis_name=result.analysis isa SmallSignal ? :frequency : result.analysis isa Transient ? :time : :point
    nodes=[node for node in result.compiled.circuit.nodes if !(node isa Ground)]
    names=Tuple(vcat(axis_name,[node.name for node in nodes]))
    columns=Any[result.axis]
    append!(columns,[voltage(result,node.name) for node in nodes])
    row_type=NamedTuple{names}
    [row_type(Tuple(column[index] for column in columns)) for index in eachindex(result.axis)]
end
