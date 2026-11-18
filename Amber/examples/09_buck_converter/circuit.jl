using Amber

"""Asynchronous buck converter with a non-ideal switch, catch diode, and LC output filter."""
@circuit BuckConverter(;
    input_voltage = 12V, switching_frequency = 250kHz, duty_cycle = 0.42,
    inductance = 47μH, capacitance = 100μF, load = 10Ω
) begin
    gnd = ground(); vin = node(); gate = node(); switching = node(); output = node()
    Input = voltage_source(vin, gnd; dc = input_voltage)
    Gate = voltage_source(
        gate, gnd; dc = 0V, waveform = Pulse(
            low = 0V, high = 5V,
            frequency = switching_frequency, duty_cycle = duty_cycle, rise = 5ns, fall = 5ns
        )
    )
    HighSide = analog_switch(
        vin, switching, gate, gnd;
        model = EventSwitch(threshold = 2.5V, ron = 80mΩ, roff = 1TΩ)
    )
    Catch = diode(
        gnd, switching; model = JunctionDiode(
            saturation_current = 20nA,
            ideality = 1.15, series_resistance = 40mΩ, junction_capacitance = 80pF,
            breakdown_voltage = 40V
        )
    )
    Filter = inductor(switching, output; value = inductance, winding_resistance = 120mΩ)
    Output = capacitor(
        output, gnd; value = capacitance, esr = 35mΩ,
        leakage_resistance = 1MΩ
    )
    Load = resistor(output, gnd; value = load)
    observe(
        voltage(gate), voltage(switching), voltage(output), current(Filter),
        current(HighSide), current(Catch), power(Load)
    )
end
