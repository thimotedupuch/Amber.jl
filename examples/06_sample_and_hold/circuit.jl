using Amber

@circuit SampleAndHold(; sampling_frequency = 100kHz, hold_capacitance = 1nF) begin
    gnd = ground(); vdd = node(); vss = node(); vin = node(); clk = node(); hold = node(); out = node()
    VDD = voltage_source(vdd, gnd; dc = 5V); VSS = voltage_source(gnd, vss; dc = 5V)
    Input = voltage_source(vin, gnd; waveform = Sine(amplitude = 1V, frequency = 7.3kHz))
    Clock = voltage_source(clk, gnd; waveform = Pulse(low = 0V, high = 5V, frequency = sampling_frequency, duty_cycle = 0.15, rise = 2ns, fall = 2ns))
    S1 = analog_switch(vin, hold, clk, gnd; model = VoltageControlledSwitch(threshold = 2.5V, ron = 15Ω, roff = 10TΩ, charge_injection = 300fC, clock_feedthrough = 20fF))
    Chold = capacitor(hold, gnd; value = hold_capacitance, leakage_resistance = 1GΩ, dielectric_absorption = DebyeBranches(time_constants = [100μs, 2ms], fractions = [0.003, 0.001]))
    Buffer = opamp(hold, out, out, vdd, vss; model = BehavioralOpAmp(dc_gain = 100dB, gain_bandwidth = 20MHz, input_bias_current = 5pA, input_capacitance = 2pF))
    observe(voltage(vin), voltage(clk), voltage(hold), voltage(out), current(S1))
end
