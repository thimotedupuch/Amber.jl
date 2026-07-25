# Diode rectifier

A rectifier connects three numerical regimes: exponential conduction, source
events, and slow energy storage. That makes it a better transient lesson than
an isolated RC network. First define the source, diode, smoothing capacitor,
and load as one reusable circuit.

```@example rectifier
using Amber

@circuit HalfWaveRectifier(; frequency=50Hz, amplitude=10V,
        load=1kΩ, smoothing=470μF) begin
    gnd=ground(); vin=node(); vout=node()
    Vac=voltage_source(vin,gnd;
        waveform=Sine(amplitude=amplitude,frequency=frequency))
    D1=diode(vin,vout;model=JunctionDiode(saturation_current=2nA,
        ideality=1.7,series_resistance=120mΩ,junction_capacitance=15pF,
        junction_potential=700mV,grading_coefficient=.45,transit_time=2μs))
    C1=capacitor(vout,gnd;value=smoothing,esr=180mΩ,
        leakage_resistance=500kΩ,dielectric_absorption=DebyeBranches(
            time_constants=[20ms,200ms,2s],fractions=[.015,.006,.002]))
    Rload=resistor(vout,gnd;value=load)
    observe(voltage(vin),voltage(vout),current(D1),charge(D1),power(D1))
end

rectifier=HalfWaveRectifier()
check(rectifier)
```

During a positive crest the diode conducts and rapidly replenishes the capacitor. Between crests the diode turns off and the load discharges the capacitor. A first estimate is

```math
\Delta V \approx \frac{I_{load}}{fC},
```

but Amber also exposes diode series loss, junction charge, capacitor ESR,
leakage, and dielectric absorption. Simulate several mains periods so startup
is clearly separated from the settled waveform.

```@example rectifier
result=transient(rectifier,0s=>500ms;reltol=1e-6,max_step=100μs)
validity_report(result)
```

Measure ripple only after discarding startup, with `periodic_metrics` or
`peak_to_peak` on the final period. Refine the maximum step near conduction
peaks: their width, not the 20 ms line period, controls the demanding time
scale.
