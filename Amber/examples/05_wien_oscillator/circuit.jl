using Amber

@circuit WienOscillator(; frequency = 10kHz) begin
    gnd = ground(); vdd = node(); vss = node(); output = node(); noninv = node(); inv = node(); series = node(); gain_n = node()
    VDD = voltage_source(vdd, gnd; dc = 12V); VSS = voltage_source(gnd, vss; dc = 12V)
    Rw = 10kΩ; Cw = 1 / (2π * Rw * frequency)
    Cseries = capacitor(output, series; value = Cw); Rseries = resistor(series, noninv; value = Rw)
    Rparallel = resistor(noninv, gnd; value = Rw); Cparallel = capacitor(noninv, gnd; value = Cw)
    Rg = resistor(inv, gnd; value = 10kΩ); Rf1 = resistor(output, gain_n; value = 12kΩ); Rf2 = resistor(gain_n, inv; value = 10kΩ)
    D1 = diode(output, gain_n; model = JunctionDiode()); D2 = diode(gain_n, output; model = JunctionDiode())
    A1 = opamp(
        noninv, inv, output, vdd, vss; model = BehavioralOpAmp(
            dc_gain = 120dB,
            gain_bandwidth = 10MHz, output_resistance = 20Ω,
            input_offset = 100μV,
            input_voltage_noise_density = 8nV / sqrt(Hz)
        )
    )
    initial_voltage(Cparallel, 1μV)
    observe(voltage(output), voltage(noninv), voltage(inv), current(D1), state(A1, :dominant_pole))
end
