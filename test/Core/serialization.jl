@testset "stable circuit serialization" begin
    original = HierarchicalFilter()
    text = serialize_circuit(original)
    @test text == serialize_circuit(original)
    @test occursin("schema = \"amber-circuit\"", text)

    restored = deserialize_circuit(text)
    @test restored.name == original.name
    @test summary(restored).nets == summary(original).nets
    @test summary(restored).primitive_devices == summary(original).primitive_devices
    @test serialize_circuit(restored) == text
    @test compile(restored).fingerprint == compile(original).fingerprint
    for field in ("connections", "parameters")
        malformed = Amber.TOML.parse(text)
        pop!(malformed["instances"][1][field])
        io = IOBuffer(); Amber.TOML.print(io, malformed)
        @test_throws CircuitSerializationError deserialize_circuit(String(take!(io)))
    end

    for invalid_index in (-1, 0, typemax(Int32)), target in (:instance, :primitive)
        malformed = Amber.TOML.parse(text)
        if target === :instance
            malformed["instances"][1]["connections"][1] = invalid_index
        else
            malformed["root_body"]["primitives"][1]["terminals"][1] = invalid_index
        end
        io = IOBuffer(); Amber.TOML.print(io, malformed)
        @test_throws CircuitSerializationError deserialize_circuit(String(take!(io)))
    end

    for invalid_index in (-1, typemax(Int32))
        malformed = Amber.TOML.parse(text)
        malformed["root_body"]["ground_net"] = invalid_index
        io = IOBuffer(); Amber.TOML.print(io, malformed)
        @test_throws CircuitSerializationError deserialize_circuit(String(take!(io)))
    end

    original_result = small_signal(original, 1kHz => 1kHz; points = 1)
    restored_result = small_signal(restored, 1kHz => 1kHz; points = 1)
    @test voltage(restored_result, :output) ≈ voltage(original_result, :output)
    @test voltage(restored_result, "First.output") ≈ voltage(original_result, "First.output")

    # Exercise every parameter representation used by the initial model set:
    # waveforms, model wrappers, vectors, tuples, hidden parasitics, and node
    # references introduced during physical elaboration.
    for modeled in (LowPass(), RealisticRC(), HalfWaveRectifier(), BiasedNPN())
        modeled_text = serialize_circuit(modeled)
        modeled_restored = deserialize_circuit(modeled_text)
        @test serialize_circuit(modeled_restored) == modeled_text
        @test compile(modeled_restored).fingerprint == compile(modeled).fingerprint
    end

    mktemp() do path, io
        close(io)
        @test save_circuit(path, original) == path
        loaded = load_circuit(path)
        @test serialize_circuit(loaded) == text
        @test_throws CircuitSerializationError load_circuit(path; max_bytes = 1)
        @test serialize_circuit(load_circuit(path; max_bytes = sizeof(text))) == text
    end

    @test_throws CircuitSerializationError deserialize_circuit("schema = \"other\"")
    bad = replace(text, "schema_version = 3" => "schema_version = 999"; count = 1)
    @test_throws CircuitSerializationError deserialize_circuit(bad)
end

@subcircuit InternalNodeSection(input, reference) begin
    middle = node()
    R1 = resistor(input, middle; value = 1kΩ)
    R2 = resistor(middle, reference; value = 1kΩ)
end
@circuit InternalNodeDesign() begin
    gnd = ground(); input = node()
    V1 = voltage_source(input, gnd; dc = 1V)
    Section = InternalNodeSection(input, gnd)
end
@testset "hierarchical serialization node limit" begin
    text = serialize_circuit(InternalNodeDesign())
    @test_throws CircuitSerializationError deserialize_circuit(text; max_nodes = 2)
    @test serialize_circuit(deserialize_circuit(text; max_nodes = 3)) == text
end

@testset "serialized integers retain large values" begin
    for value in (typemax(Int128), typemin(Int128), typemax(UInt128), big(1) << 200, -(big(1) << 200))
        encoded = Amber._encode_value(value)
        @test Amber._decode_value(encoded, Dict(), Dict()) == value
    end
end

@testset "serialized named tuple field order" begin
    value = (z = 1.0, a = 2.0)
    restored = Amber._decode_value(Amber._encode_value(value), Dict(), Dict())
    @test keys(restored) == keys(value)
    @test restored == value
    invalid = Amber._encode_value(UInt128(1)); invalid["value"] = "-1"
    @test_throws ArgumentError Amber._decode_value(invalid, Dict(), Dict())
end
