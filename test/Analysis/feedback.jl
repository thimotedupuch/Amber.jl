@testset "bias-preserving loop analysis" begin
    @circuit FeedbackReference() begin
        gnd=ground(); input=node(); output=node()
        Probe=voltage_source(input,gnd;dc=0V,ac=1V)
        E1=voltage_controlled_voltage_source(input,gnd,output,gnd;gain=10.)
        R1=resistor(output,gnd;value=1kΩ)
    end
    circuit=FeedbackReference(); before=operating_point(circuit)
    result=loop_gain(circuit,[10Hz,1kHz];probe=VoltageLoopProbe(:Probe,voltage(:output);sign=1))
    after=operating_point(circuit)
    @test result.values≈fill(10+0im,2)
    @test before.values==after.values
    @test result.stats[:bias_preserved]
    @test loop_sensitivity(result)≈fill(inv(11),2)
    @test !isdefined(Amber,:return_ratio)

    bad=with_parameters(compile(FeedbackReference()),"Probe.dc"=>1V)
    @test_throws ArgumentError loop_gain(bad,[1kHz];probe=VoltageLoopProbe(:Probe,voltage(:output)))
end
