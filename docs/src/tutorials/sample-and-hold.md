# Sample and hold

A sample-and-hold combines continuous dynamics with discrete events. Switch
resistance sets acquisition time; hold capacitance trades acquisition speed
against droop and charge error. Define the input, clock, switch, storage
capacitor, and output buffer explicitly.

```@example sample_hold
using Amber

@circuit SampleAndHold(; sampling_frequency=100kHz,
        hold_capacitance=1nF) begin
    gnd=ground(); vdd=node(); vss=node(); vin=node(); clk=node()
    hold=node(); out=node()
    VDD=voltage_source(vdd,gnd;dc=5V)
    VSS=voltage_source(gnd,vss;dc=5V)
    Input=voltage_source(vin,gnd;
        waveform=Sine(amplitude=1V,frequency=7.3kHz))
    Clock=voltage_source(clk,gnd;waveform=Pulse(low=0V,high=5V,
        frequency=sampling_frequency,duty_cycle=.15,rise=2ns,fall=2ns))
    S1=analog_switch(vin,hold,clk,gnd;model=VoltageControlledSwitch(
        threshold=2.5V,ron=15Ω,roff=10TΩ,charge_injection=300fC,
        clock_feedthrough=20fF))
    Chold=capacitor(hold,gnd;value=hold_capacitance,
        leakage_resistance=1GΩ,dielectric_absorption=DebyeBranches(
            time_constants=[100μs,2ms],fractions=[.003,.001]))
    Buffer=opamp(hold,out,out,vdd,vss;model=BehavioralOpAmp(
        dc_gain=100dB,gain_bandwidth=20MHz,input_bias_current=5pA,
        input_capacitance=2pF,slew_rate=10V/μs))
    observe(voltage(vin),voltage(clk),voltage(hold),voltage(out),current(S1))
end

sampler=SampleAndHold()
check(sampler)
```

The clock waveform contributes exact transition breakpoints. The switch includes on/off resistance, clock feedthrough, and falling-edge charge injection; the capacitor includes leakage and optional dielectric absorption. The buffer loads the held node through its behavioral input model.

Run in exact event mode so the clock transitions become solver breakpoints, then
measure acquisition and held-value error from the resulting traces.

```@example sample_hold
result=transient(sampler,0s=>1ms;event_mode=:exact,max_step=50ns)
errors=sampling_metrics(result;input=voltage(:vin),held=voltage(:hold),
    clock=voltage(:clk))
```

Repeat with a smaller maximum step around both clock edges. The current model
injects charge only for prescribed falling control transitions, so do not
generalize it to arbitrary analog control trajectories.
