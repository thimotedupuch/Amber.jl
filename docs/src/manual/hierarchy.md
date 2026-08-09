# Hierarchy and reusable subcircuits

`@subcircuit` defines reusable hierarchy with explicit ports and parameters. Instances retain qualified paths for diagnostics, results, sweeps, and Monte Carlo.

```@example hierarchy
using Amber
@subcircuit RCSection(input, output, reference; resistance=1kΩ, capacitance=1μF) begin
    R = resistor(input, output; value=resistance)
    C = capacitor(output, reference; value=capacitance)
end

@circuit TwoPoleLadder() begin
    gnd = ground(); vin = node(); mid = node(); out = node()
    Drive = voltage_source(vin, gnd; dc=1V)
    First = RCSection(vin, mid, gnd; resistance=1kΩ, capacitance=1μF)
    Second = RCSection(mid, out, gnd; resistance=1kΩ, capacitance=1μF)
    observe(voltage(out))
end

design = TwoPoleLadder()
voltage(operating_point(design), :out)[1]
```

Paths such as `First.R` remain available to diagnostics and parameter studies. Use `instances(design)`, `devices(design)`, `nets(design)`, and `resolve(design, path)` to inspect retained hierarchy without flattening it.

Subcircuits must receive their reference net as an explicit port; `ground()` is only valid at the top level. Parameterize blocks with physical values and model objects so the same template remains usable in sweeps and statistical experiments.
