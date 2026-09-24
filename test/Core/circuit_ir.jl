@testset "circuit IR and hierarchy" begin
    c = LowPass(); @test summary(c).primitive_devices == 3; @test length(c.observations.values) == 2
    hierarchical = HierarchicalFilter()
    @test resolve(hierarchical, "First.R1").kind == :device
    @test resolve(hierarchical, "Second.C1").kind == :device
    @circuit GeneratedLadder(; sections = 4) begin
        gnd = ground(); previous = node()
        voltage_source(previous, gnd; dc = 1V)
        for index in 1:sections
            following = node()
            resistor(previous, following; value = index * 1kΩ)
            previous = following
        end
        resistor(previous, gnd; value = 1kΩ)
    end
    generated = GeneratedLadder()
    @test summary(generated).primitive_devices == 6
    @test isempty(check(generated))
    @test length(LowPass().observations.values) == 2
end


@testset "IR invariants and fingerprints" begin
    source = LowPass(); compiled = compile(source); fingerprint = compiled.fingerprint
    updated = with_parameters(compiled, "R1.value" => 20kΩ)
    @test updated.fingerprint != fingerprint
    @test compiled.fingerprint == fingerprint
    @test updated.topology === compiled.topology
    @test !isdefined(Amber, :Circuit)
    @test !isdefined(Amber, :Component)
end
