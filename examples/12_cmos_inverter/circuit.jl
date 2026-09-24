using Amber

const CMOS_NMOS = Level1MOSFET(
    threshold_voltage = 0.7V,
    transconductance = 2mA / V^2, channel_length_modulation = 0.03 / V,
    body_effect = 0.35sqrt(V), surface_potential = 0.35V,
    gate_source_capacitance = 8pF, gate_drain_capacitance = 2pF
)
const CMOS_PMOS = Level1MOSFET(
    threshold_voltage = 0.7V,
    transconductance = 1mA / V^2, channel_length_modulation = 0.03 / V,
    body_effect = 0.35sqrt(V), surface_potential = 0.35V,
    gate_source_capacitance = 8pF, gate_drain_capacitance = 2pF
)

@circuit CMOSInverter(;
    supply_voltage = 5V, input_voltage = 0V, waveform = nothing,
    load_capacitance = 20pF
) begin
    gnd = ground(); supply = node(); input = node(); output = node()
    VDD = voltage_source(supply, gnd; dc = supply_voltage)
    Input = voltage_source(input, gnd; dc = input_voltage, ac = 1V, waveform)
    PullUp = pmos(output, input, supply, supply; model = CMOS_PMOS)
    PullDown = nmos(output, input, gnd, gnd; model = CMOS_NMOS)
    Load = capacitor(output, gnd; value = load_capacitance)
    observe(
        voltage(input), voltage(output), current(PullUp), current(PullDown),
        power(PullUp), power(PullDown)
    )
end
