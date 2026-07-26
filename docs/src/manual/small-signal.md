# Small-signal AC analysis

`small_signal` linearizes the circuit about its DC operating point and solves the complex frequency-domain system. A nonlinear device contributes its local derivatives at the chosen bias—not a separate approximate AC model.

```@example ac
using Amber
@circuit RCLowPass() begin
    gnd = ground()
    vin = node()
    out = node()
    Input = voltage_source(vin, gnd; dc=0V, ac=1V)
    R1 = resistor(vin, out; value=1kΩ)
    C1 = capacitor(out, gnd; value=1μF)
    observe(voltage(out))
end

r = small_signal(RCLowPass(), 1Hz => 10kHz; source=:Input, points=21)
gain = magnitude(voltage(r, :out))
(gain[1], gain[end])
```

Use `frequencies`, `trace`, `transfer`, `magnitude`, and `phase` to inspect results. Frequencies are in hertz; internal phasor equations use ``\omega=2\pi f``.

Because this is a local linearization, verify the DC bias and intended source. Large-signal distortion, slew, switching, and clipping require transient analysis.
