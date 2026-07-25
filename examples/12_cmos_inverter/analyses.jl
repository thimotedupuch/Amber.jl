include("circuit.jl")

dc_transfer=[voltage(operating_point(CMOSInverter(input_voltage=value)),:output)[1]
    for value in range(0V,5V;length=101)]

switching=CMOSInverter(waveform=Pulse(low=0V,high=5V,frequency=10MHz,
    duty_cycle=.5,rise=1ns,fall=1ns))
waveforms=transient(switching,0s=>500ns;event_mode=:exact,max_step=1ns)
delay=propagation_delay(waveforms;input=voltage(:input),output=voltage(:output),
    threshold=2.5V)
