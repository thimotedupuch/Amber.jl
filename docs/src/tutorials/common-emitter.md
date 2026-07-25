# Common-emitter amplifier

This amplifier shows why DC, AC, transient, and noise analyses belong to one
circuit definition. The circuit includes biasing, coupling and bypass
capacitors, source and load impedances, and a physical BJT model.

```@example common_emitter
using Amber

@circuit CommonEmitterAmplifier(; VCC=12V, RC=4.7kΩ, RE=1kΩ) begin
    gnd=ground(); vcc=node(); src=node(); drive=node(); base=node()
    emit=node(); coll=node(); out=node()
    Supply=voltage_source(vcc,gnd;dc=VCC)
    Input=voltage_source(src,gnd;dc=0V,ac=1V,
        waveform=Sine(amplitude=10mV,frequency=1kHz))
    Rsource=resistor(src,drive;value=600Ω)
    Cin=capacitor(drive,base;value=10μF)
    Rbias1=resistor(vcc,base;value=82kΩ)
    Rbias2=resistor(base,gnd;value=18kΩ)
    Rcollector=resistor(vcc,coll;value=RC)
    Remitter=resistor(emit,gnd;value=RE)
    Cemit=capacitor(emit,gnd;value=100μF)
    Q1=npn(coll,base,emit;model=GummelPoonBJT(saturation_current=8fA,
        forward_beta=180.,early_voltage=80V,base_resistance=25Ω,
        cbe_zero_bias=20pF,cbc_zero_bias=4pF,transit_time=300ps,
        flicker_noise=true))
    Cout=capacitor(coll,out;value=10μF)
    Rload=resistor(out,gnd;value=10kΩ)
    observe(voltage(base),voltage(emit),voltage(coll),voltage(out),
        current(Q1,:collector),current(Q1,:base),power(Q1))
end
```

Start at the operating point. It establishes collector current and the local
transistor derivatives used by the linearized analyses.

```@example common_emitter
amplifier=CommonEmitterAmplifier()
op=operating_point(amplifier)
(voltage(op, :base)[1], voltage(op, :emit)[1], voltage(op, :coll)[1])
```

AC analysis reveals the coupling-capacitor high-pass corners, midband
inversion, emitter-bypass behavior, and device-capacitance roll-off.

```@example common_emitter
ac=small_signal(amplifier,10Hz=>100MHz;source=:Input,points=600)
gain=transfer(ac;input=voltage(:src),output=voltage(:out))
```

Transient analysis answers the different question of clipping and waveform
distortion. Noise analysis refers device noise through the same biased
small-signal system.

```@example common_emitter
noise_result=noise(amplifier,10Hz=>1MHz;output=voltage(:out),
    referred_to=:Input,points=300)
```

Before trusting gain, check that the transistor is in forward active operation
with adequate collector-emitter headroom. Compare the midband result with
``-g_m(R_C\parallel R_L)`` and the input resistance with the bias network in
parallel with the transistor input.
