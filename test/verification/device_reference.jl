@testset "verification: nonlinear device references" begin
    temperature=325.; thermal=Amber._thermal_voltage(temperature)
    model=JunctionDiode(saturation_current=2nA,ideality=1.4,breakdown_voltage=5V,breakdown_current=1nA)
    @circuit BiasedDiode(;bias=.55V,model=model) begin
        gnd=ground(); terminal=node(); Bias=voltage_source(terminal,gnd;dc=bias); D1=diode(terminal,gnd;model)
    end
    forward=operating_point(BiasedDiode();temperature)
    expected_forward=model.saturation_current*expm1(.55V/(thermal*model.ideality))
    @test current(forward,:D1)[1]≈expected_forward rtol=2e-10
    reverse=operating_point(BiasedDiode(bias=-5.05V);temperature)
    @test reverse.stats[:converged]
    expected_reverse=model.saturation_current*expm1(-5.05V/(thermal*model.ideality))-model.breakdown_current*expm1((5.05V-model.breakdown_voltage)/(thermal*model.ideality))
    @test current(reverse,:D1)[1]≈expected_reverse rtol=2e-10

    transistor=GummelPoonBJT(saturation_current=10fA,forward_beta=120.,reverse_beta=2.,early_voltage=80V)
    @circuit VoltageBiasedBJT(;model=transistor) begin
        gnd=ground(); collector=node(); base=node(); emitter=node()
        VC=voltage_source(collector,gnd;dc=3V); VB=voltage_source(base,gnd;dc=.68V); VE=voltage_source(emitter,gnd;dc=0V)
        Q1=npn(collector,base,emitter;model)
    end
    bjt=operating_point(VoltageBiasedBJT();temperature)
    If=transistor.saturation_current*expm1(.68V/thermal); Ir=transistor.saturation_current*expm1((.68V-3V)/thermal)
    αf=transistor.forward_beta/(transistor.forward_beta+1); αr=transistor.reverse_beta/(transistor.reverse_beta+1)
    expected_collector=αf*If*(1+3V/transistor.early_voltage)-Ir
    expected_base=(1-αf)*If+(1-αr)*Ir
    @test current(bjt,:Q1,:collector)[1]≈expected_collector rtol=2e-10
    @test current(bjt,:Q1,:base)[1]≈expected_base rtol=2e-10
end

@testset "verification: behavioral op-amp reference" begin
    gain=1e4; bandwidth=1MHz
    @circuit FollowerReference() begin
        gnd=ground(); positive=node(); negative=node(); input=node(); output=node()
        VP=voltage_source(positive,gnd;dc=5V); VN=voltage_source(gnd,negative;dc=5V)
        Input=voltage_source(input,gnd;dc=.1V,ac=1V)
        A1=opamp(input,output,output,positive,negative;model=BehavioralOpAmp(dc_gain=gain,gain_bandwidth=bandwidth,output_resistance=0Ω))
    end
    follower=operating_point(FollowerReference())
    @test voltage(follower,:output)[1]≈gain/(1+gain)*.1V rtol=2e-8
    response=small_signal(FollowerReference(),bandwidth=>bandwidth;source=:Input)
    expected=gain/(1+gain+im*gain)
    @test voltage(response,:output)[1]≈expected rtol=2e-8
end
