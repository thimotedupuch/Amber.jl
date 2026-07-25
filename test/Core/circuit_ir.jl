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


@testset "IR invariants and fingerprints" begin
    first_circuit=LowPass(); second_circuit=LowPass()
    only(filter(component->component.name===:R1,second_circuit.components)).parameters[:value]*=2
    @test compile(first_circuit).fingerprint!=compile(second_circuit).fingerprint

    duplicate=LowPass(); push!(duplicate.components,deepcopy(first(duplicate.components)))
    @test any(diagnostic->occursin("Component names must be unique",diagnostic.message),check(duplicate))

    foreign=LowPass(); other=Circuit(:other); foreign_node=node!(other,:foreign)
    first(foreign.components).terminals[1]=foreign_node
    @test any(diagnostic->occursin("does not belong",diagnostic.message),check(foreign))

    source=LowPass(); compiled=compile(source); fingerprint=compiled.fingerprint
    only(filter(component->component.name===:R1,source.components)).parameters[:value]*=3
    @test compiled.fingerprint==fingerprint
    @test only(filter(component->component.name===:R1,compiled.circuit.components)).parameters[:value]==10kΩ
end
