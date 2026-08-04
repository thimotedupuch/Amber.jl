@testset "controlled sources" begin
    @test !isdefined(Amber,:source)
    @test !isdefined(Amber,:voltage_amplifier)
    @test !isdefined(Amber,:current_amplifier)
    @test !isdefined(Amber,:transresistance)
    @circuit TransconductanceStage() begin
        gnd=ground(); input=node(); output=node()
        Vin=voltage_source(input,gnd;dc=1V,ac=1V)
        G1=transconductance(input,gnd,output,gnd;gm=1mA/V)
        Rload=resistor(output,gnd;value=1kΩ)
    end
    op=operating_point(TransconductanceStage())
    @test voltage(op,:output)[1]≈-1V
    @test current(op,:G1)[1]≈1mA
    @circuit VoltageGainStage() begin
        gnd=ground(); input=node(); output=node(); Vin=voltage_source(input,gnd;dc=1V)
        E1=voltage_controlled_voltage_source(input,gnd,output,gnd;gain=3.)
    end
    @test voltage(operating_point(VoltageGainStage()),:output)[1]≈3V
    @circuit CurrentControlledStages() begin
        gnd=ground(); sense=node(); current_output=node(); voltage_output=node()
        Vsense=voltage_source(sense,gnd;dc=1V)
        Rsense=resistor(sense,gnd;value=1kΩ)
        F1=current_controlled_current_source(Vsense,current_output,gnd;gain=2.)
        Rload=resistor(current_output,gnd;value=1kΩ)
        H1=current_controlled_voltage_source(Vsense,voltage_output,gnd;transresistance=1kΩ)
    end
    controlled=operating_point(CurrentControlledStages())
    @test voltage(controlled,:current_output)[1]≈2V
    @test voltage(controlled,:voltage_output)[1]≈-1V
    @test current(controlled,:F1)[1]≈-2mA
    invalid_builder=CircuitBuilder(:InvalidControl); reference=ground!(invalid_builder,:gnd); output=node!(invalid_builder,:node)
    controller=add!(invalid_builder,resistor(output,reference;value=1kΩ);name=:Rcontrol)
    add!(invalid_builder,current_controlled_current_source(controller,output,reference;gain=2.);name=:Fbad)
    invalid=finish(invalid_builder)
    @test_throws CircuitValidationError compile(invalid)
end
