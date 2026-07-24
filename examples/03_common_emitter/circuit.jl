using Amber

@circuit CommonEmitterAmplifier(;VCC=12V,RC=4.7kΩ,RE=1kΩ) begin
    gnd=ground(); vcc=node(); src=node(); drive=node(); base=node(); emit=node(); coll=node(); out=node()
    Supply=voltage_source(vcc,gnd;dc=VCC)
    Input=voltage_source(src,gnd;dc=0V,ac=1V,waveform=Sine(amplitude=10mV,frequency=1kHz))
    Rsource=resistor(src,drive;value=600Ω); Cin=capacitor(drive,base;value=10μF)
    Rbias1=resistor(vcc,base;value=82kΩ); Rbias2=resistor(base,gnd;value=18kΩ)
    Rcollector=resistor(vcc,coll;value=RC); Remitter=resistor(emit,gnd;value=RE)
    Cemit=capacitor(emit,gnd;value=100μF)
    Q1=npn(coll,base,emit;model=GummelPoonBJT(saturation_current=8fA,forward_beta=180.,early_voltage=80V,base_resistance=25Ω,cbe_zero_bias=20pF,cbc_zero_bias=4pF,transit_time=300ps,flicker_noise=true))
    Cout=capacitor(coll,out;value=10μF); Rload=resistor(out,gnd;value=10kΩ)
    observe(voltage(base),voltage(emit),voltage(coll),voltage(out),current(Q1,:collector),current(Q1,:base),power(Q1))
end
