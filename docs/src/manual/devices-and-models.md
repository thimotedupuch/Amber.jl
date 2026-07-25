# Devices and models

Amber separates convenient device constructors from physical model values. Constructors such as `resistor`, `diode`, `npn`, `opamp`, and `analog_switch` connect terminals and accept either direct parameters or a model object.

- `JunctionDiode` implements exponential junction current, optional breakdown, series resistance, depletion charge, and transit charge.
- `GummelPoonBJT` provides a compact NPN model with forward and reverse transport, Early effect, junction capacitances, and optional base resistance.
- `BehavioralOpAmp` models finite open-loop gain and bandwidth, rails, offset, bias currents, input capacitance, and output resistance.
- `VoltageControlledSwitch` selects smooth or event-oriented resistance transitions and can model feedthrough and charge injection.

These models are deliberately focused. They are useful for circuit reasoning and numerical experimentation, not drop-in foundry models. MOS devices are not yet in the core, and some declared behavioral op-amp limits are reserved rather than enforced. Read [Physical model scope](@ref) and [Current limitations](@ref) before interpreting edge-of-validity results.

```@example models
using Amber
fast_diode = JunctionDiode(Is=2e-12, n=1.05, Cj0=2e-12)
fast_diode
```

