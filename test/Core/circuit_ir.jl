@testset "circuit IR and hierarchy" begin
    c=LowPass(); @test length(c.components)==3; @test length(c.observations)==2
    hierarchical=HierarchicalFilter()
    @test any(x->x.name==Symbol("First.R1"),hierarchical.components)
    @test any(x->x.name==Symbol("Second.C1"),hierarchical.components)
    @circuit GeneratedLadder(;sections=4) begin
        gnd=ground(); previous=node()
        voltage_source(previous,gnd;dc=1V)
        for index in 1:sections
            following=node()
            resistor(previous,following;value=index*1kΩ)
            previous=following
        end
        resistor(previous,gnd;value=1kΩ)
    end
    generated=GeneratedLadder()
    @test length(generated.components)==6
    @test isempty(check(generated))
    @test all(x->x isa Amber.Observable,LowPass().observations)
end
