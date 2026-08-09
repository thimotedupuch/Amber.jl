@testset "stable circuit serialization" begin
    original=HierarchicalFilter()
    text=serialize_circuit(original)
    @test text==serialize_circuit(original)
    @test occursin("schema = \"amber-circuit\"",text)

    restored=deserialize_circuit(text)
    @test restored.name==original.name
    @test summary(restored).nets==summary(original).nets
    @test summary(restored).primitive_devices==summary(original).primitive_devices
    @test serialize_circuit(restored)==text
    @test compile(restored).fingerprint==compile(original).fingerprint

    original_result=small_signal(original,1kHz=>1kHz;points=1)
    restored_result=small_signal(restored,1kHz=>1kHz;points=1)
    @test voltage(restored_result,:output)≈voltage(original_result,:output)
    @test voltage(restored_result,"First.output")≈voltage(original_result,"First.output")

    # Exercise every parameter representation used by the initial model set:
    # waveforms, model wrappers, vectors, tuples, hidden parasitics, and node
    # references introduced during physical elaboration.
    for modeled in (LowPass(),RealisticRC(),HalfWaveRectifier(),BiasedNPN())
        modeled_text=serialize_circuit(modeled)
        modeled_restored=deserialize_circuit(modeled_text)
        @test serialize_circuit(modeled_restored)==modeled_text
        @test compile(modeled_restored).fingerprint==compile(modeled).fingerprint
    end

    mktemp() do path,io
        close(io)
        @test save_circuit(path,original)==path
        loaded=load_circuit(path)
        @test serialize_circuit(loaded)==text
    end

    @test_throws CircuitSerializationError deserialize_circuit("schema = \"other\"")
    bad=replace(text,"schema_version = 3"=>"schema_version = 999";count=1)
    @test_throws CircuitSerializationError deserialize_circuit(bad)
end
