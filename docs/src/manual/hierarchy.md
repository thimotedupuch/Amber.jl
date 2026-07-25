# Hierarchy and reusable subcircuits

Ordinary Julia functions are Amber's primary composition mechanism. A helper receives a circuit and boundary nodes, creates consistently named elements, and returns useful handles.

```@example hierarchy
using Amber
function rc_section!(c, prefix, input, output, gnd; r, capacitance)
    add!(c, resistor(input, output; value=r); name=Symbol(prefix, ".r"))
    add!(c, capacitor(output, gnd; value=capacitance); name=Symbol(prefix, ".c"))
    output
end
c = Circuit(:two_pole_ladder)
vin, mid, out = (node!(c, n) for n in (:vin, :mid, :out)); gnd = ground!(c)
add!(c, voltage_source(vin, gnd; dc=1.0); name=:drive)
rc_section!(c, "stage1", vin, mid, gnd; r=1e3, capacitance=1e-6)
rc_section!(c, "stage2", mid, out, gnd; r=1e3, capacitance=1e-6)
observe!(c, voltage(out))
voltage(operating_point(c), :out)[1]
```

This style keeps hierarchy transparent: there is one circuit graph and names such as `stage1.r` remain available to diagnostics and Monte Carlo parameter paths. Amber does not currently preserve nested instances as a separate runtime object model. Prefix names consistently when composing repeated blocks.

Return nodes, component handles, or a small named tuple from helpers rather than searching by position later. Parameterize helpers with physical values and model objects; this makes the same block usable in sweeps and statistical experiments.
