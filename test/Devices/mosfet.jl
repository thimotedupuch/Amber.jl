using LinearAlgebra: norm

@testset "level-1 MOSFET and CMOS" begin
    model=Level1MOSFET(threshold_voltage=1V,transconductance=2mA/V^2,
        channel_length_modulation=.02/V,body_effect=0.,
        gate_source_capacitance=2pF,gate_drain_capacitance=.5pF)

    @circuit BiasedNMOS() begin
        gnd=ground(); drain=node(); gate=node()
        VD=voltage_source(drain,gnd;dc=3V)
        VG=voltage_source(gate,gnd;dc=2.5V)
        M1=nmos(drain,gate,gnd,gnd;model)
    end
    nresult=operating_point(BiasedNMOS())
    expected=.5model.transconductance*(2.5V-model.threshold_voltage)^2*(1+model.channel_length_modulation*3V)
    @test current(nresult,:M1)[1]≈expected rtol=2e-10
    @test region(nresult,:M1)==Saturation
    @test available_observables(only(filter(x->x.name===:M1,BiasedNMOS().components)))==(:voltage,:current,:power)

    @circuit BiasedPMOS() begin
        gnd=ground(); supply=node(); drain=node(); gate=node()
        VDD=voltage_source(supply,gnd;dc=5V)
        VD=voltage_source(drain,gnd;dc=2V)
        VG=voltage_source(gate,gnd;dc=2.5V)
        M1=pmos(drain,gate,supply,supply;model)
    end
    presult=operating_point(BiasedPMOS())
    @test current(presult,:M1)[1]≈-expected rtol=2e-10
    @test region(presult,:M1)==Saturation

    @circuit CMOSInverter(;input_voltage=2.5V,waveform=nothing) begin
        gnd=ground(); supply=node(); input=node(); output=node()
        VDD=voltage_source(supply,gnd;dc=5V)
        Input=voltage_source(input,gnd;dc=input_voltage,ac=1V,waveform)
        PullUp=pmos(output,input,supply,supply;model)
        PullDown=nmos(output,input,gnd,gnd;model)
        Load=capacitor(output,gnd;value=10pF)
        observe(voltage(input),voltage(output),current(PullUp),current(PullDown))
    end
    low=operating_point(CMOSInverter(input_voltage=0V))
    high=operating_point(CMOSInverter(input_voltage=5V))
    @test voltage(low,:output)[1]>4.99V
    @test voltage(high,:output)[1]<.01V

    switching=CMOSInverter(waveform=Pulse(low=0V,high=5V,frequency=10MHz,
        duty_cycle=.5,rise=1ns,fall=1ns))
    transient_result=transient(switching,0s=>200ns;event_mode=:exact,max_step=1ns)
    @test transient_result.stats[:converged]
    @test maximum(voltage(transient_result,:output))>4V
    @test minimum(voltage(transient_result,:output))<1V

    response=small_signal(CMOSInverter(),1kHz=>1MHz;source=:Input,points=3)
    @test all(isfinite,voltage(response,:output))
    @test real(voltage(response,:output)[1])<0
    noise_result=noise(CMOSInverter(),1kHz=>10kHz;output=voltage(:output),points=3)
    @test all(>(0),noise_density(noise_result))

    serialized=serialize_circuit(CMOSInverter())
    restored=deserialize_circuit(serialized)
    @test serialize_circuit(restored)==serialized
    @test restored.components[3].parameters[:model] isa Level1MOSFET

    compiled=compile(CMOSInverter()); point=operating_point(compiled).values[:,1]
    previous=point .- range(1e-7,4e-7;length=compiled.n); α=2e5
    _,analytic=Amber.residual_jacobian(compiled,point,previous,0.,α)
    numerical=Amber._jacobian(z->Amber.residual(compiled,z,α.*(z.-previous),0.),point)
    @test norm(Matrix(analytic)-numerical)/max(norm(numerical),eps())<2e-5
end
