# Reading results

Every simulation result contains an analysis axis, an unknown matrix, solver
statistics, and a snapshot of its compiled circuit. Prefer named observable
accessors over indexing the matrix directly.

```@example reading_results
using Amber

@circuit ResultExample() begin
    gnd = ground()
    input = node()
    output = node()
    V1 = voltage_source(input, gnd; dc=2V)
    R1 = resistor(input, output; value=1kΩ)
    R2 = resistor(output, gnd; value=1kΩ)
end

result = operating_point(ResultExample())
(
    voltage=voltage(result, :output)[1],
    current=current(result, :R1)[1],
    power=power(result, :R1)[1],
)
```

Voltage is measured from the named node to ground unless a second node is
given. Device current is positive from the first terminal to the second. Power
is positive when a device absorbs energy and negative when it delivers energy;
see [Sign conventions](@ref).

Always inspect solver status before trusting derived metrics:

```@example reading_results
result.stats
```

`status == :converged` is the concise success indicator. A failed transient
may still contain an explicitly marked partial trajectory. Use
[`explain_failure`](@ref) to turn recorded residual information into a named
node, branch, or state.

[`provenance`](@ref) records the topology fingerprint, parameter snapshot,
analysis type, units, statistics, and warnings. [`result_table`](@ref) exposes
results through the Tables.jl-compatible row interface without introducing a
mandatory dataframe dependency.
