@testset "network parameters" begin
    @circuit OnePortResistor() begin
        gnd=ground(); terminal=node()
        R1=resistor(terminal,gnd;value=2kΩ)
    end
    result=port_response(OnePortResistor(),[10Hz,1kHz];ports=Port(:terminal,:gnd))
    @test vec(impedance(result))≈fill(2kΩ,2)
    @test vec(admittance(result))≈fill(inv(2kΩ),2)
    @test size(network_parameters(result,:s))==(1,1,2)
    changed=renormalize(result,75Ω)
    @test only(changed.ports).reference_impedance==75Ω
    @test impedance(changed)==impedance(result)

    @circuit TwoPortNetwork() begin
        gnd=ground(); first=node(); second=node()
        Rseries=resistor(first,second;value=1kΩ)
        Rinput=resistor(first,gnd;value=2kΩ)
        Routput=resistor(second,gnd;value=3kΩ)
    end
    two=port_response(TwoPortNetwork(),1kHz=>1kHz;ports=[Port(:first,:gnd),Port(:second,:gnd)],points=1)
    z=impedance(two)[:,:,1]
    @test z≈transpose(z)
    @test network_parameters(two,:y)[:,:,1]*z≈[1 0;0 1]
    @test size(network_parameters(two,:abcd))==(2,2,1)
    @test size(network_parameters(two,:h))==(2,2,1)
end
