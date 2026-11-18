using Amber

# A current-output light sensor followed by a smooth threshold detector.
@circuit LightDetector begin
    gnd = ground(); sense = node(); threshold = node(); output = node()
    sensor = photodiode(sense, gnd; photocurrent = 20μA)
    load = resistor(sense, gnd; value = 10kΩ)
    reference = voltage_source(threshold, gnd; dc = 0.1V)
    detector = comparator(sense, threshold, output, gnd; low = 0V, high = 3.3V)
    resistor(output, gnd; value = 10kΩ)
end

# A passive transformer and adjustable load divider.
@circuit TransformerDivider begin
    gnd = ground(); primary = node(); secondary = node(); tap = node()
    supply = voltage_source(primary, gnd; dc = 10V, ac = 1V)
    T = ideal_transformer(primary, gnd, secondary, gnd; ratio = 2.0)
    pot = potentiometer(secondary, tap, gnd; resistance = 100Ω, position = 0.25)
end

if abspath(PROGRAM_FILE) == @__FILE__
    light = operating_point(LightDetector())
    divider = operating_point(TransformerDivider())
    @assert voltage(light, :output)[1] ≈ 3.3V
    @assert voltage(divider, :tap)[1] ≈ 1.25V
    println("Light detector output: ", voltage(light, :output)[1], " V")
    println("Transformer tap: ", voltage(divider, :tap)[1], " V")
end
