@testset "two-injection loop return ratio" begin
    @circuit FeedbackReference(;reverse=false) begin
        gnd=ground(); input=node(); output=node()
        if reverse
            Probe=voltage_source(output,input;dc=0V)
        else
            Probe=voltage_source(input,output;dc=0V)
        end
        Injection=current_source(input,gnd;dc=0A)
        E1=voltage_controlled_voltage_source(gnd,input,output,gnd;gain=10.)
        R1=resistor(output,gnd;value=1kΩ)
    end
    circuit=FeedbackReference(); before=operating_point(circuit)
    result=loop_gain(circuit,[10Hz,1kHz];probe=VoltageLoopProbe(:Probe,voltage(:output)))
    @test result.values≈fill(10+0im,2)
    @test before.values==operating_point(circuit).values
    @test result.stats[:bias_preserved]
    @test result.stats[:method]===:tian_two_injection
    @test loop_sensitivity(result)≈fill(inv(11),2)
    @test closed_loop_response(result)≈fill(10/11,2)
    reversed=loop_gain(FeedbackReference(reverse=true),[10Hz,1kHz];
        probe=VoltageLoopProbe(:Probe,voltage(:output)))
    @test reversed.values≈result.values
    injected=loop_gain(circuit,[10Hz,1kHz];probe=CurrentLoopProbe(:Injection,current(:Probe)))
    @test injected.values≈result.values

    # Independent analytic two-port with reverse transmission and unequal loads.
    # Cut Y = [g1+s*c1, reverse_gm; forward_gm, g2+s*c2].
    @circuit BilateralFeedback() begin
        gnd=ground(); a=node(); b=node()
        Probe=voltage_source(a,b;dc=0.)
        G1=conductance(a,gnd;value=.002)
        G2=conductance(b,gnd;value=.003)
        C1=capacitor(a,gnd;value=1e-9)
        C2=capacitor(b,gnd;value=2e-9)
        Forward=transconductance(a,gnd,b,gnd;gm=.04)
        Reverse=transconductance(b,gnd,a,gnd;gm=.001)
    end
    fs=[10.,1e5,1e6]
    bilateral=loop_gain(BilateralFeedback(),fs;probe=VoltageLoopProbe(:Probe,voltage(:b)))
    @test bilateral.values≈.041 ./ (.005 .+ im.*2π.*fs.*3e-9) rtol=1e-12

    bad=with_parameters(compile(circuit),"Probe.dc"=>1V)
    @test_throws ArgumentError loop_gain(bad,[1kHz];probe=VoltageLoopProbe(:Probe,voltage(:output)))
    @test_throws ArgumentError loop_gain(circuit,[1kHz];probe=VoltageLoopProbe(:Probe,voltage(:output,:input)))
    @test_throws ArgumentError loop_gain(circuit,[1kHz];probe=CurrentLoopProbe(:Injection,voltage(:output)))
end
