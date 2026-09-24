@subcircuit TestRCSection(input, output, reference; R = 1kΩ, C = 1nF) begin
    R1 = resistor(input, output; value = R)
    C1 = capacitor(output, reference; value = C)
    observe(output; name = :output)
end

@testset "hierarchical circuit construction" begin
    builder = CircuitBuilder(:Ladder)
    reference = ground!(builder, :gnd)
    nodes = node_array!(builder, :x, 0:8)
    add!(builder, voltage_source(nodes[0], reference; dc = 1V); name = :Source)
    stage_handles = instances!(
        builder,
        TestRCSection,
        1:8;
        name = index -> (:stage, index),
        connections = index -> (
            input = nodes[index - 1],
            output = nodes[index],
            reference = reference,
        ),
        parameters = index -> (R = (1 + index / 8) * 1kΩ, C = 1nF),
    )
    design = finish(builder)

    @test nodes[0].id == 2
    @test stage_handles[8].id == InstanceId(8)
    @test summary(design).templates == 1
    @test summary(design).instances == 8
    @test summary(design).primitive_devices == 17
    @test string(parsepath("stage[4].R1")) == "stage[4].R1"
    @test resolve(design, "stage[4].R1").kind == :device
    @test length(instances(design; limit = 3)) == 3
    @test length(devices(design; kind = :resistor)) == 8
    @test occursin("Primitive devices: 17", describe(design; limit = 2))

    serialized = serialize_circuit(design)
    restored = deserialize_circuit(serialized)
    @test restored isa CircuitDesign
    @test serialize_circuit(restored) == serialized
    @test summary(restored) == summary(design)

    compiled = compile(restored)
    @test !hasproperty(compiled, :circuit)
    @test compiled.hierarchical_topology.hierarchy.primitive_count == 17
    @test compiled.n == 10
    result = operating_point(restored)
    @test voltage(result, "x[8]")[1] ≈ 1V

    foreign_builder = CircuitBuilder(:foreign)
    foreign_node = node!(foreign_builder, :foreign)
    @test_throws Amber.BuilderOwnershipError add!(foreign_builder, resistor(nodes[0], foreign_node; value = 1kΩ))
    finish(foreign_builder)
    @test_throws Amber.BuilderOwnershipError node!(foreign_builder, :late)
end

@testset "legacy flat API removed" begin
    @test !isdefined(Amber, :Circuit)
    @test !isdefined(Amber, :Component)
    @test !isdefined(Amber, :Node)
    @test !isdefined(Amber, :Ground)
    @test !isdefined(Amber, :migrate_design)
end

@testset "named observation registration" begin
    builder = CircuitBuilder(:NamedMeasurements)
    gnd = ground!(builder); out = node!(builder, :out)
    add!(builder, resistor(out, gnd; value = 1kΩ); name = :R1)
    observe!(builder, voltage(out); name = :output)
    @test_throws ArgumentError observe!(builder, voltage(out); name = "output")
    @test_throws ArgumentError observe!(builder, voltage(out), current(:R1); name = :both)
    @test_throws ArgumentError observe!(builder; name = :empty)
    # Rejected calls must not register anything; unnamed multi-value calls remain valid.
    observe!(builder, voltage(out), current(:R1))
    design = finish(builder)
    @test length(observations(design)) == 3
    @test only(filter(o -> o.name !== nothing, observations(design))).name === :output
    @test only(observation(operating_point(design), :output)) == 0V
end
