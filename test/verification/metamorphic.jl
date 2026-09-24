@testset "verification: representation invariance" begin
    @circuit FlatReference() begin
        gnd = ground(); input = node(); middle = node(); output = node()
        V1 = voltage_source(input, gnd; dc = 3V, ac = 1V)
        R1 = resistor(input, middle; value = 1kΩ); C1 = capacitor(middle, gnd; value = 10nF)
        R2 = resistor(middle, output; value = 2kΩ); C2 = capacitor(output, gnd; value = 20nF)
        Load = resistor(output, gnd; value = 10kΩ)
    end
    original = FlatReference(); restored = deserialize_circuit(serialize_circuit(original))
    first_result = operating_point(original); second_result = operating_point(restored)
    @test voltage(first_result, :middle) ≈ voltage(second_result, :middle) rtol = 1.0e-12
    @test voltage(first_result, :output) ≈ voltage(second_result, :output) rtol = 1.0e-12

    @circuit RenamedReference() begin
        zero = ground(); source_node = node(); intermediate = node(); result_node = node()
        source = voltage_source(source_node, zero; dc = 3V, ac = 1V)
        first_resistor = resistor(source_node, intermediate; value = 1kΩ); first_capacitor = capacitor(intermediate, zero; value = 10nF)
        second_resistor = resistor(intermediate, result_node; value = 2kΩ); second_capacitor = capacitor(result_node, zero; value = 20nF)
        load = resistor(result_node, zero; value = 10kΩ)
    end
    renamed = RenamedReference()
    renamed_result = operating_point(renamed)
    @test sort(first_result.values[:, 1]) ≈ sort(renamed_result.values[:, 1]) rtol = 1.0e-12
end
