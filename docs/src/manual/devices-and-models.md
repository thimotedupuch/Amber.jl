# Devices and models

Amber separates convenient device constructors from physical model values. Constructors such as `resistor`, `diode`, `npn`, `nmos`, `pmos`, `opamp`, and `analog_switch` connect terminals and accept either direct parameters or a model object.

- `JunctionDiode` implements exponential junction current, optional breakdown, series resistance, depletion charge, and transit charge.
- `GummelPoonBJT` provides a compact NPN model with forward and reverse transport, Early effect, junction capacitances, and optional base resistance.
- `Level1MOSFET` provides symmetric NMOS and PMOS channel equations with body effect, triode and saturation regions, channel-length modulation, fixed intrinsic gate capacitances, and channel thermal noise.
- `BehavioralOpAmp` models finite open-loop gain and bandwidth, rails, offset, bias currents, input capacitance, and output resistance.
- `VoltageControlledSwitch` selects smooth or event-oriented resistance transitions and can model feedthrough and charge injection.

These models are deliberately focused. They are useful for circuit reasoning and numerical experimentation, not drop-in foundry models. The MOSFET model is a level-1 model rather than BSIM, and some declared behavioral op-amp limits are reserved rather than enforced. Read [Physical model scope](@ref) and [Current limitations](@ref) before interpreting edge-of-validity results.

```@example models
using Amber
logic_device=Level1MOSFET(threshold_voltage=.7V,
    transconductance=2mA/V^2,channel_length_modulation=.03/V,
    gate_source_capacitance=8pF,gate_drain_capacitance=2pF)
logic_device
```

`nmos(drain, gate, source, bulk; model=...)` and
`pmos(drain, gate, source, bulk; model=...)` always use a positive threshold
voltage magnitude. Connect the NMOS bulk to its lowest rail and the PMOS bulk
to its highest rail for the usual CMOS configuration.
