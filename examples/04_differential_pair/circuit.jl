using Amber

@circuit DifferentialPair(;tail_current=1mA,collector_resistance=5.6kΩ) begin
    gnd=ground(); vdd=node(); vss=node(); inp=node(); inn=node(); tail=node(); outp=node(); outn=node()
    VDD=voltage_source(vdd,gnd;dc=5V); VSS=voltage_source(gnd,vss;dc=5V)
    Vplus=voltage_source(inp,gnd;dc=1.2V,ac=.5V); Vminus=voltage_source(inn,gnd;dc=1.2V,ac=-.5V)
    Itail=current_source(tail,vss;dc=tail_current)
    RC1=resistor(vdd,outp;value=collector_resistance); RC2=resistor(vdd,outn;value=collector_resistance)
    pair=matched_group(:input_pair;sigma_vbe=300μV,sigma_log_beta=.03,correlation=.2)
    Q1=npn(outp,inp,tail;model=GummelPoonBJT(),match=pair)
    Q2=npn(outn,inn,tail;model=GummelPoonBJT(),match=pair)
    observe(voltage(outp),voltage(outn),voltage(outp,outn),current(Q1,:collector),current(Q2,:collector))
end
