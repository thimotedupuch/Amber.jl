@subcircuit CompilerRCSection(input, output, reference; R=1kΩ, C=1nF) begin
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, reference; value=C)
end

@subcircuit CompilerControlledSection(reference, sense, current_output, voltage_output) begin
    Sense = voltage_source(sense, reference; dc=1V)
    Rsense = resistor(sense, reference; value=1kΩ)
    F1 = current_controlled_current_source(Sense, current_output, reference; gain=2.0)
    Rload = resistor(current_output, reference; value=1kΩ)
    H1 = current_controlled_voltage_source(Sense, voltage_output, reference; transresistance=1kΩ)
end

function compiler_ladder(sections=8)
    builder = CircuitBuilder(:CompilerLadder)
    reference = ground!(builder, :gnd)
    nodes = node_array!(builder, :x, 0:sections)
    add!(builder, voltage_source(nodes[0], reference; dc=1V); name=:Source)
    instances!(builder, CompilerRCSection, 1:sections;
        name=index -> (:stage, index),
        connections=index -> (input=nodes[index - 1], output=nodes[index], reference=reference),
        parameters=index -> (R=index * 1kΩ, C=1nF))
    finish(builder)
end

function assembly_allocations(workspace, compiled, state_values, previous)
    residual_jacobian!(workspace, compiled, state_values, previous, 1μs, 1e5)
    @allocated residual_jacobian!(workspace, compiled, state_values, previous, 1μs, 1e5)
end

@testset "streamed hierarchy compiler" begin
    compiled = compile(compiler_ladder())
    hierarchy = compiled.hierarchical_topology.hierarchy
    pattern = compiled.hierarchical_topology.pattern

    @test compiled.design isa CircuitDesign
    @test hierarchy.primitive_count == 17
    @test hierarchy.solver_net_count == 9
    @test hierarchy.unknown_count == compiled.n == 10
    @test pattern.colptr == compiled.jacobian_pattern.colptr
    @test pattern.rowval == compiled.jacobian_pattern.rowval
    @test all(diff(pattern.colptr) .>= 0)
    @test all(pattern.diagonal_slots .> 0)

    resistor_batch = only(batch for batch in compiled.parameters.batches if batch isa ResistorBatch)
    @test length(resistor_batch.p) == 8
    @test resistor_batch.conductance == 1.0 ./ (collect(1:8) .* 1kΩ)
    @test all(resistor_batch.jacobian_slots .> 0)
    @test length(unique(resistor_batch.locators)) == 8

    updated = with_parameters(compiled, "stage[1:3].R1.value" => 10kΩ)
    updated_resistors = only(batch for batch in updated.parameters.batches if batch isa ResistorBatch)
    original_capacitors = only(batch for batch in compiled.parameters.batches if batch isa PrimitiveBatch && typeof(batch).parameters[1] === Val{:capacitor})
    updated_capacitors = only(batch for batch in updated.parameters.batches if batch isa PrimitiveBatch && typeof(batch).parameters[1] === Val{:capacitor})
    @test updated.hierarchical_topology === compiled.hierarchical_topology
    @test updated_capacitors === original_capacitors
    @test updated_resistors !== resistor_batch
    @test updated_resistors.p === resistor_batch.p
    @test updated_resistors.conductance[1:3] == fill(1 / 10kΩ, 3)
    @test updated.parameters.fingerprint != compiled.parameters.fingerprint
    @test all(component.parameters[:value] == 10kΩ for component in updated.circuit.components if String(component.name) in ("stage[1].R1", "stage[2].R1", "stage[3].R1"))
    @test compile(updated) === updated
    @test_throws TopologyParameterError with_parameters(compiled, "stage[1].R1.package" => SMD0603())
    @test_throws KeyError with_parameters(compiled, "stage[99].R1.value" => 2kΩ)

    workspace = SimulationWorkspace(compiled)
    state_values = collect(range(0.1, 1.0; length=compiled.n))
    previous = state_values .- 0.01
    batch_residual, batch_jacobian = residual_jacobian!(workspace, compiled, state_values, previous, 1μs, 1e5)
    reference_residual, reference_jacobian = Amber.residual_jacobian(compiled, state_values, previous, 1μs, 1e5)
    @test batch_residual ≈ reference_residual atol=1e-18 rtol=1e-14
    @test Matrix(batch_jacobian) ≈ Matrix(reference_jacobian) atol=1e-15 rtol=4eps(Float64)
    @test assembly_allocations(workspace, compiled, state_values, previous) == 0
end

@testset "controlled-source batch topology" begin
    builder = CircuitBuilder(:CompilerControlled)
    reference = ground!(builder, :gnd)
    sense = node!(builder, :sense)
    current_output = node!(builder, :current_output)
    voltage_output = node!(builder, :voltage_output)
    instance!(builder, CompilerControlledSection, reference, sense, current_output, voltage_output; instance_name=:block)
    compiled = compile(finish(builder))
    pattern = compiled.hierarchical_topology.pattern
    @test pattern.colptr == compiled.jacobian_pattern.colptr
    @test pattern.rowval == compiled.jacobian_pattern.rowval
    result = operating_point(compiled)
    @test voltage(result, :current_output)[1] ≈ 2V
    @test voltage(result, :voltage_output)[1] ≈ -1V
end


@testset "linear RLGC workspace assembly" begin
    compiled = compile(migrate_design(RLGCLine(sections=3)))
    workspace = SimulationWorkspace(compiled)
    state_values = collect(range(-0.2, 0.3; length=compiled.n))
    previous = state_values .- 1e-3
    batch_residual, batch_jacobian = residual_jacobian!(workspace, compiled, state_values, previous, 2ns, 1e9)
    reference_residual, reference_jacobian = Amber.residual_jacobian(compiled, state_values, previous, 2ns, 1e9)
    @test batch_residual ≈ reference_residual atol=1e-12 rtol=1e-13
    @test Matrix(batch_jacobian) ≈ Matrix(reference_jacobian) atol=1e-15 rtol=4eps(Float64)
    @test assembly_allocations(workspace, compiled, state_values, previous) == 0
end
