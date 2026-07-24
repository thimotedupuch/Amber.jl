using Amber

@circuit HalfWaveRectifier(;frequency=50Hz,amplitude=10V,load=1kΩ,smoothing=470μF) begin
    gnd=ground(); vin=node(); vout=node()
    Vac=voltage_source(vin,gnd;waveform=Sine(amplitude=amplitude,frequency=frequency))
    D1=diode(vin,vout;model=JunctionDiode(saturation_current=2nA,ideality=1.7,series_resistance=120mΩ,junction_capacitance=15pF,junction_potential=700mV,grading_coefficient=.45,transit_time=2μs))
    C1=capacitor(vout,gnd;value=smoothing,esr=180mΩ,leakage_resistance=500kΩ,dielectric_absorption=DebyeBranches(time_constants=[20ms,200ms,2s],fractions=[.015,.006,.002]))
    Rload=resistor(vout,gnd;value=load)
    observe(voltage(vin),voltage(vout),current(D1),charge(D1),power(D1))
end
