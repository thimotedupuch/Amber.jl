using Amber

const RING_NMOS=Level1MOSFET(threshold_voltage=.7V,
    transconductance=2mA/V^2,channel_length_modulation=.03/V,
    gate_source_capacitance=2pF,gate_drain_capacitance=.5pF)
const RING_PMOS=Level1MOSFET(threshold_voltage=.7V,
    transconductance=1mA/V^2,channel_length_modulation=.03/V,
    gate_source_capacitance=2pF,gate_drain_capacitance=.5pF)

"""One loaded CMOS inverter stage with explicit signal and supply ports."""
@subcircuit RingStage(input,output,supply,reference;load_capacitance=5pF,
        initial_output=nothing) begin
    PullUp=pmos(output,input,supply,supply;model=RING_PMOS)
    PullDown=nmos(output,input,reference,reference;model=RING_NMOS)
    Load=capacitor(output,reference;value=load_capacitance)
    if initial_output!==nothing
        initial_voltage(Load,initial_output)
    end
end

"""Five-stage autonomous CMOS ring oscillator with a deliberate startup imbalance."""
@circuit CMOSRingOscillator(;supply_voltage=5V,load_capacitance=5pF,
        startup_offset=50mV) begin
    gnd=ground(); supply=node()
    stage1=node(); stage2=node(); stage3=node(); stage4=node(); stage5=node()
    VDD=voltage_source(supply,gnd;dc=supply_voltage)
    First=RingStage(stage5,stage1,supply,gnd;load_capacitance,
        initial_output=supply_voltage/2+startup_offset)
    Second=RingStage(stage1,stage2,supply,gnd;load_capacitance,
        initial_output=supply_voltage/2-startup_offset)
    Third=RingStage(stage2,stage3,supply,gnd;load_capacitance,
        initial_output=supply_voltage/2+startup_offset)
    Fourth=RingStage(stage3,stage4,supply,gnd;load_capacitance,
        initial_output=supply_voltage/2-startup_offset)
    Fifth=RingStage(stage4,stage5,supply,gnd;load_capacitance,
        initial_output=supply_voltage/2+startup_offset)
    observe(voltage(stage1),voltage(stage2),voltage(stage3),voltage(stage4),
        voltage(stage5),current(VDD))
end
