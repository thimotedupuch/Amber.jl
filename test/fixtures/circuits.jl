@circuit LowPass(;R=10kΩ,C=10nF) begin
    gnd=ground(); vin=node(); vout=node()
    V1=voltage_source(vin,gnd;dc=0V,ac=1V,waveform=Step(low=0V,high=1V,at=100μs))
    R1=resistor(vin,vout;value=R); C1=capacitor(vout,gnd;value=C)
    observe(voltage(vout),current(R1))
end

@circuit BiasedNPN() begin
    gnd=ground(); vcc=node(); base=node(); coll=node(); emit=node()
    Supply=voltage_source(vcc,gnd;dc=5V); Rb=resistor(vcc,base;value=220kΩ)
    Rc=resistor(vcc,coll;value=2kΩ); Re=resistor(emit,gnd;value=500Ω)
    Q1=npn(coll,base,emit;model=GummelPoonBJT(forward_beta=150.))
end

@circuit RealisticRC() begin
    gnd=ground(); a=node(); b=node()
    Vin=voltage_source(a,gnd;waveform=Sine(amplitude=1V,frequency=1kHz))
    R1=resistor(a,b;value=10kΩ,material=ThinFilm(tc1=15e-6/K),package=SMD0603(series_inductance=.6nH))
    C1=capacitor(b,gnd;value=10nF,dielectric=C0G(loss_tangent=1e-4),package=SMD0603(esr=30mΩ))
end

@circuit HalfWaveRectifier(;frequency=50Hz,amplitude=10V,load=1kΩ,smoothing=470μF) begin
    gnd=ground(); vin=node(); vout=node()
    Vac=voltage_source(vin,gnd;waveform=Sine(amplitude=amplitude,frequency=frequency))
    D1=diode(vin,vout;model=JunctionDiode(saturation_current=2nA,ideality=1.7,series_resistance=120mΩ,junction_capacitance=15pF,transit_time=2μs))
    C1=capacitor(vout,gnd;value=smoothing,esr=180mΩ,leakage_resistance=500kΩ,dielectric_absorption=DebyeBranches(time_constants=[20ms,200ms,2s],fractions=[.015,.006,.002]))
    Rload=resistor(vout,gnd;value=load)
    observe(voltage(vin),voltage(vout),current(D1),charge(D1),power(D1))
end

function RLGCLine(;sections=5)
    builder=CircuitBuilder(:RLGCLine); gnd=ground!(builder,:gnd); x=node_array!(builder,:x,0:sections)
    add!(builder,voltage_source(x[0],gnd;waveform=Step(at=1ns,rise=100ps));name=:Vin)
    for k in 1:sections
        middle=node!(builder,(:middle,k)); add!(builder,resistor(x[k-1],middle;value=.01Ω);name=(:R,k))
        add!(builder,inductor(middle,x[k];value=1nH);name=(:L,k)); add!(builder,conductance(x[k],gnd;value=1μS);name=(:G,k))
        add!(builder,capacitor(x[k],gnd;value=1pF);name=(:C,k))
    end
    add!(builder,resistor(x[sections],gnd;value=50Ω);name=:Rload)
    observe!(builder,voltage(x[0]),voltage(x[sections])); finish(builder)
end

@subcircuit RCSection(input,output,reference;R=1kΩ,C=10nF) begin
    R1=resistor(input,output;value=R); C1=capacitor(output,reference;value=C)
    observe(voltage(output),current(R1))
end
@circuit HierarchicalFilter() begin
    gnd=ground(); input=node(); middle=node(); output=node(); Vin=voltage_source(input,gnd;ac=1V)
    First=RCSection(input,middle,gnd;R=1kΩ,C=10nF); Second=RCSection(middle,output,gnd;R=2kΩ,C=20nF)
end
