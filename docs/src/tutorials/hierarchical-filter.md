# Hierarchical active filter

This example composes reusable active-filter sections into a fourth-order
filter. It demonstrates that hierarchy can preserve meaningful names without
hiding the final numerical graph. Begin with a section whose external nodes
are explicit ports.

```@example hierarchical_filter
using Amber

@circuit SallenKeySection(input,output,positive_rail,negative_rail;
        R=10kΩ,C=10nF) begin
    gnd=ground(); first_node=node(); sense=node()
    R1=resistor(input,first_node;value=R)
    R2=resistor(first_node,sense;value=R)
    C1=capacitor(first_node,output;value=C)
    C2=capacitor(sense,gnd;value=C)
    Buffer=opamp(sense,output,output,positive_rail,negative_rail;
        model=BehavioralOpAmp(dc_gain=110dB,gain_bandwidth=10MHz,
            output_resistance=5Ω,input_capacitance=2pF))
end
```

Instantiate the section twice in the top-level circuit. `First` and `Second`
become stable hierarchical prefixes for inspection and parameter paths.

```@example hierarchical_filter
@circuit HierarchicalActiveFilter(; R1=10kΩ,C1=10nF,
        R2=15kΩ,C2=6.8nF) begin
    gnd=ground(); positive_rail=node(); negative_rail=node()
    input=node(); middle=node(); output=node()
    PositiveSupply=voltage_source(positive_rail,gnd;dc=12V)
    NegativeSupply=voltage_source(gnd,negative_rail;dc=12V)
    Source=voltage_source(input,gnd;dc=0V,ac=1V,
        waveform=Step(low=0V,high=1V,at=10μs,rise=100ns))
    First=SallenKeySection(input,middle,positive_rail,negative_rail;R=R1,C=C1)
    Second=SallenKeySection(middle,output,positive_rail,negative_rail;R=R2,C=C2)
    Load=resistor(output,gnd;value=100kΩ)
    observe(voltage(input),voltage(middle),voltage(output))
end

filter=HierarchicalActiveFilter()
check(filter)
```

Analyze the nominal DC point first, then compare the AC response with the
intended pole placement.

```@example hierarchical_filter
bias=operating_point(filter)
response=small_signal(filter,10Hz=>1MHz;source=:Source,points=400)
gain=transfer(response;input=voltage(:input),output=voltage(:output))
```

A transient step reveals settling and rail interaction that a linear transfer
function cannot.

```@example hierarchical_filter
step_response=transient(filter,0s=>1ms;saveat=1μs)
```
