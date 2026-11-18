using Amber

@circuit PracticalLowPass(; R = 10kΩ, C = 10nF) begin
    gnd = ground(); vin = node(); vout = node()
    Vin = voltage_source(vin, gnd; dc = 0V, ac = 1V, waveform = Step(low = 0V, high = 1V, at = 100μs, rise = 10ns))
    R1 = resistor(
        vin, vout; value = R, material = ThinFilm(excess_noise_coefficient = 1.0e-18),
        package = SMD0603(series_inductance = 0.6nH, parallel_capacitance = 40fF)
    )
    C1 = capacitor(vout, gnd; value = C, dielectric = C0G(), package = SMD0603(esr = 30mΩ, esl = 500pH))
    observe(voltage(vout), current(R1), power(R1), current(C1))
end
