using Amber

"""Reusable unity-gain Sallen–Key section with explicit supply ports."""
@subcircuit SallenKeySection(input,output,positive_rail,negative_rail,reference;R=10kΩ,C=10nF) begin
    first_node=node(); sense=node()
    R1=resistor(input,first_node;value=R)
    R2=resistor(first_node,sense;value=R)
    C1=capacitor(first_node,output;value=C)
    C2=capacitor(sense,reference;value=C)
    Buffer=opamp(sense,output,output,positive_rail,negative_rail;
        model=BehavioralOpAmp(dc_gain=110dB,gain_bandwidth=10MHz,
            output_resistance=5Ω,input_capacitance=2pF))
end

"""Fourth-order active low-pass assembled from two hierarchical sections."""
@circuit HierarchicalActiveFilter(;R1=10kΩ,C1=10nF,R2=15kΩ,C2=6.8nF) begin
    gnd=ground(); positive_rail=node(); negative_rail=node(); input=node(); middle=node(); output=node()
    PositiveSupply=voltage_source(positive_rail,gnd;dc=12V)
    NegativeSupply=voltage_source(gnd,negative_rail;dc=12V)
    Source=voltage_source(input,gnd;dc=0V,ac=1V,
        waveform=Step(low=0V,high=1V,at=10μs,rise=100ns))
    First=SallenKeySection(input,middle,positive_rail,negative_rail,gnd;R=R1,C=C1)
    Second=SallenKeySection(middle,output,positive_rail,negative_rail,gnd;R=R2,C=C2)
    Load=resistor(output,gnd;value=100kΩ)
    observe(voltage(input),voltage(middle),voltage(output))
end
