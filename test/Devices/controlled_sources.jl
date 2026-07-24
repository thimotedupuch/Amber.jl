@testset "controlled sources" begin
    @circuit TransconductanceStage() begin
        gnd=ground(); input=node(); output=node()
        Vin=voltage_source(input,gnd;dc=1V,ac=1V)
        G1=transconductance(input,gnd,output,gnd;gm=1mA/V)
        Rload=resistor(output,gnd;value=1kΩ)
    end
    op=operating_point(TransconductanceStage())
    @test voltage(op,:output)[1]≈-1V
    @circuit VoltageGainStage() begin
        gnd=ground(); input=node(); output=node(); Vin=voltage_source(input,gnd;dc=1V)
        E1=voltage_amplifier(input,gnd,output,gnd;gain=3.)
    end
    @test voltage(operating_point(VoltageGainStage()),:output)[1]≈3V
    @circuit CurrentControlledStages() begin
        gnd=ground(); sense=node(); current_output=node(); voltage_output=node()
        Vsense=voltage_source(sense,gnd;dc=1V)
        Rsense=resistor(sense,gnd;value=1kΩ)
        F1=current_amplifier(Vsense,current_output,gnd;gain=2.)
        Rload=resistor(current_output,gnd;value=1kΩ)
        H1=transresistance(Vsense,voltage_output,gnd;value=1kΩ)
    end
    controlled=operating_point(CurrentControlledStages())
    @test voltage(controlled,:current_output)[1]≈2V
    @test voltage(controlled,:voltage_output)[1]≈-1V
    invalid=Circuit(:InvalidControl); reference=ground!(invalid,:gnd); node=node!(invalid,:node)
    controller=add!(invalid,resistor(node,reference;value=1kΩ);name=:Rcontrol)
    add!(invalid,current_amplifier(controller,node,reference;gain=2.);name=:Fbad)
    @test_throws ArgumentError compile(invalid)
end
