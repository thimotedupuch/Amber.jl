# Transient analysis

`transient` integrates the differential-algebraic circuit equations over time. Amber supports first- and second-order backward differentiation (BDF1/BDF2), fixed or adaptive stepping, exact source breakpoints, and exact requested save times.

```@example tran
using Amber
@circuit RCStep() begin
    gnd = ground()
    vin = node()
    out = node()
    Source = voltage_source(vin, gnd; waveform=Step(low=0V, high=1V, at=0s))
    R1 = resistor(vin, out; value=1kΩ)
    C1 = capacitor(out, gnd; value=1μF, initial_voltage=0V)
    observe(voltage(out))
end

r = transient(RCStep(), 0s => 5ms; saveat=0.5ms)
(first(r.axis), last(r.axis), length(r.axis))
```

Initial conditions constrain energy-storage elements; they do not replace a consistent circuit state. Source discontinuities force breakpoints so integration does not step across a known event. Adaptive stepping controls a local numerical estimate, not model accuracy.

For switching circuits, inspect time resolution around every transition and repeat with tighter tolerances or a smaller maximum step. Agreement of one endpoint can hide ringing or event-timing errors.
