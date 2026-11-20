using Amber, AmberSchematics

@subcircuit Driver(positive, negative) begin
    coil = node()
    Re = resistor(positive, coil; value = 8)
    Le = inductor(coil, negative; value = 0.3e-3)
end

@circuit SpeakerCrossover() begin
    gnd = ground()
    amp = node(); drive = node()
    V1 = voltage_source(amp, gnd; waveform = Sine(amplitude = 1, frequency = 1000))
    Rs = resistor(amp, drive; value = 0.22)

    bass1 = node(); bass2 = node(); bass = node()
    L1 = inductor(drive, bass1; value = 2.2e-3)
    C1 = capacitor(bass1, gnd; value = 68e-6)
    L2 = inductor(bass1, bass2; value = 1.5e-3)
    C2 = capacitor(bass2, gnd; value = 47e-6)
    R1 = resistor(bass2, bass; value = 0.47)
    R2 = resistor(bass, gnd; value = 33)
    XW = Driver(bass, gnd)

    mid1 = node(); mid2 = node(); mid = node()
    C3 = capacitor(drive, mid1; value = 33e-6)
    L3 = inductor(mid1, gnd; value = 2.2e-3)
    L4 = inductor(mid1, mid2; value = 0.47e-3)
    C4 = capacitor(mid2, gnd; value = 6.8e-6)
    R3 = resistor(mid2, mid; value = 1.5)
    R4 = resistor(mid, gnd; value = 22)
    XM = Driver(mid, gnd)

    high1 = node(); high2 = node(); high = node()
    C5 = capacitor(drive, high1; value = 6.8e-6)
    L5 = inductor(high1, gnd; value = 0.33e-3)
    C6 = capacitor(high1, high2; value = 4.7e-6)
    L6 = inductor(high2, gnd; value = 0.22e-3)
    R5 = resistor(high2, high; value = 2.2)
    R6 = resistor(high, gnd; value = 18)
    XT = Driver(high, gnd)
end

source_x, feed_x, driver_x, return_x = -4.8, -2.0, 12.0, 14.4
feed_y, ground_y = 2.2, -13.8
placements = Dict(:V1 => Placement(source_x, -4.6; rotation = 270),
    :Rs => Placement(source_x, 0; rotation = 90))
labels = Dict(
    :V1 => "V1 · Amplifier\n1 kHz test tone", :Rs => "Rs\n0.22 Ω",
    :L1 => "L1\n2.2 mH", :C1 => "C1\n68 μF", :L2 => "L2\n1.5 mH",
    :C2 => "C2\n47 μF", :R1 => "R1\n0.47 Ω", :R2 => "R2\n33 Ω",
    :C3 => "C3\n33 μF", :L3 => "L3\n2.2 mH", :L4 => "L4\n0.47 mH",
    :C4 => "C4\n6.8 μF", :R3 => "R3\n1.5 Ω", :R4 => "R4\n22 Ω",
    :C5 => "C5\n6.8 μF", :L5 => "L5\n0.33 mH", :C6 => "C6\n4.7 μF",
    :L6 => "L6\n0.22 mH", :R5 => "R5\n2.2 Ω", :R6 => "R6\n18 Ω",
    :XW => "XW · Woofer", :XM => "XM · Midrange", :XT => "XT · Tweeter",
)
wires = [Wire((:V1, 1), (:Rs, 1))]
for (y, series, shunts, driver) in (
    (0, (:L1, :L2, :R1), (:C1, :C2, :R2), :XW),
    (-4.6, (:C3, :L4, :R3), (:L3, :C4, :R4), :XM),
    (-9.2, (:C5, :C6, :R5), (:L5, :L6, :R6), :XT),
)
    return_y = y - 4.05
    placements[driver] = Placement(driver_x, y - 2.0; rotation = 270)
    push!(wires, Wire((:Rs, 2), (first(series), 1);
        via = [(source_x, feed_y), (feed_x, feed_y), (feed_x, y)]))

    for (index, (part, shunt)) in enumerate(zip(series, shunts))
        x = 3.8 * (index - 1)
        shunt_x = x + 1.9
        placements[part] = Placement(x, y)
        placements[shunt] = Placement(shunt_x, y - 1.7; rotation = 270)
        push!(wires, Wire((part, 2), (shunt, 1); via = [(shunt_x, y)]))
        if index < length(series)
            push!(wires, Wire((part, 2), (series[index + 1], 1)))
        end
    end
    push!(wires, Wire((last(series), 2), (driver, 1); via = [(driver_x, y)]))

    returns = (shunts..., driver)
    for (left, right) in zip(returns, Base.tail(returns))
        left_x, right_x = placements[left].center[1], placements[right].center[1]
        push!(wires, Wire((left, 2), (right, 2);
            via = [(left_x, return_y), (right_x, return_y)]))
    end
    push!(wires, Wire((driver, 2), (:V1, 2);
        via = [(driver_x, return_y), (return_x, return_y),
            (return_x, ground_y), (source_x, ground_y)]))
end

drawing = schematic(SpeakerCrossover(); placements, labels, wires,
    symbols = Dict(:V1 => :sine_source),
    net_markers = Dict(:drive => (feed_x, feed_y), :gnd => (4, ground_y)))
for path in (isempty(ARGS) ? ["speaker-crossover.svg"] : ARGS)
    save_schematic(path, drawing)
end
