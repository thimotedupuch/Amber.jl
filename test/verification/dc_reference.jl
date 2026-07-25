@testset "verification: linear DC references" begin
    @circuit DividerReference() begin
        gnd=ground(); source_node=node(); first=node(); second=node()
        V1=voltage_source(source_node,gnd;dc=12V)
        R1=resistor(source_node,first;value=2kΩ)
        R2=resistor(first,second;value=3kΩ)
        R3=resistor(second,gnd;value=5kΩ)
        R4=resistor(first,gnd;value=10kΩ)
    end
    result=operating_point(DividerReference())
    conductance=[inv(2kΩ)+inv(3kΩ)+inv(10kΩ) -inv(3kΩ); -inv(3kΩ) inv(3kΩ)+inv(5kΩ)]
    expected=conductance\[12V/2kΩ,0.]
    @test [voltage(result,:first)[1],voltage(result,:second)[1]]≈expected rtol=1e-11

    @circuit BridgeReference() begin
        gnd=ground(); supply=node(); left=node(); right=node()
        V1=voltage_source(supply,gnd;dc=5V)
        R1=resistor(supply,left;value=1kΩ); R2=resistor(left,gnd;value=2kΩ)
        R3=resistor(supply,right;value=3kΩ); R4=resistor(right,gnd;value=4kΩ)
        R5=resistor(left,right;value=5kΩ)
    end
    bridge=operating_point(BridgeReference())
    g1,g2,g3,g4,g5=inv.((1kΩ,2kΩ,3kΩ,4kΩ,5kΩ))
    exact=[g1+g2+g5 -g5; -g5 g3+g4+g5]\[g1*5V,g3*5V]
    @test voltage(bridge,:left)[1]≈exact[1] rtol=1e-11
    @test voltage(bridge,:right)[1]≈exact[2] rtol=1e-11
end

