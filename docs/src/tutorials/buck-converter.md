# Buck converter

The asynchronous buck converter is a compact stress test for event timing,
nonlinear diode conduction, and widely separated time scales. Its circuit model
keeps the important losses visible rather than hiding them in an ideal transfer
ratio.

```@example buck
using Amber
using Statistics

@circuit BuckConverter(; input_voltage=12V, switching_frequency=250kHz,
        duty_cycle=.42, inductance=47μH, capacitance=100μF,
        load=10Ω) begin
    gnd=ground(); vin=node(); gate=node(); switching=node(); output=node()
    Input=voltage_source(vin,gnd;dc=input_voltage)
    Gate=voltage_source(gate,gnd;dc=0V,waveform=Pulse(low=0V,high=5V,
        frequency=switching_frequency,duty_cycle=duty_cycle,
        rise=5ns,fall=5ns))
    HighSide=analog_switch(vin,switching,gate,gnd;
        model=EventSwitch(threshold=2.5V,ron=80mΩ,roff=1TΩ))
    Catch=diode(gnd,switching;model=JunctionDiode(
        saturation_current=20nA,ideality=1.15,series_resistance=40mΩ,
        junction_capacitance=80pF,breakdown_voltage=40V))
    Filter=inductor(switching,output;value=inductance,
        winding_resistance=120mΩ)
    Output=capacitor(output,gnd;value=capacitance,esr=35mΩ,
        leakage_resistance=1MΩ)
    Load=resistor(output,gnd;value=load)
    observe(voltage(gate),voltage(switching),voltage(output),current(Filter),
        current(HighSide),current(Catch),power(Load))
end

converter=BuckConverter()
check(converter)
```

The ideal continuous-conduction estimate is ``V_o\approx D V_{in}``. Inductor winding resistance, switch resistance, diode drop, capacitor ESR, and discontinuous conduction all move the simulated value. Never validate this example from average output alone: inspect switch-node voltage, inductor-current ripple, diode current, output ripple, and load power.

Run long enough to separate startup from the periodic steady regime. Exact event
handling aligns the integration with gate edges; `saveat` controls the stored
output grid independently.

```@example buck
startup=transient(converter,0s=>2ms;initial=:discharged,event_mode=:exact,
    max_step=100ns,saveat=1μs,reltol=1e-5)
```

Compute metrics over the settled portion of the run. For detailed ripple or
loss measurements, use an integer number of switching periods and retain a
fine enough output grid.

```@example buck
output_ripple=peak_to_peak(voltage(:output);window=1.5ms=>2ms)(startup)
average_output=mean(voltage(startup,:output)[startup.axis.>=1.5ms])
(average_output,output_ripple)
```

Reduce the maximum step until ripple and switching-loss indicators stabilize.
