using Amber

@circuit DocsVoltageDivider(; supply=5V, top=2kΩ, bottom=1kΩ) begin
    gnd=ground(); input=node(); output=node()
    Source=voltage_source(input,gnd;dc=supply)
    Rtop=resistor(input,output;value=top); Rbottom=resistor(output,gnd;value=bottom)
    observe(voltage(output),current(Rtop),power(Rbottom))
end
divider=DocsVoltageDivider()
@assert isempty(check(divider))
op=operating_point(divider)
@assert op.stats[:converged]
@assert isapprox(only(voltage(op,:output)),5V*1kΩ/3kΩ)
@assert isapprox(only(current(op,:Rtop)),5V/3kΩ)
@assert length(result_table(op))==1

@circuit DocsRCStep(;R=10kΩ,C=10nF) begin
    gnd=ground(); input=node(); output=node()
    Source=voltage_source(input,gnd;dc=0V,waveform=Step(low=0V,high=1V,at=100μs,rise=1μs))
    R1=resistor(input,output;value=R); C1=capacitor(output,gnd;value=C)
end
tran=transient(DocsRCStep(),0s=>600μs;saveat=2μs,max_step=2μs)
@assert tran.stats[:converged]
@assert voltage(tran,:output)[end]>.98V

@circuit DocsRCLowPass(;R=10kΩ,C=10nF) begin
    gnd=ground(); input=node(); output=node()
    Source=voltage_source(input,gnd;dc=0V,ac=1V)
    R1=resistor(input,output;value=R); C1=capacitor(output,gnd;value=C)
end
ac=small_signal(DocsRCLowPass(),10Hz=>1MHz;source=:Source,points=301,scale=:log)
gain=transfer(ac;input=voltage(:input),output=voltage(:output))
corner=inv(2π*10kΩ*10nF); corner_index=argmin(abs.(frequencies(ac).-corner))
@assert isapprox(db20(abs(gain[corner_index])),-3.0103;atol=.15)

@subcircuit DocsRCSection(input,output,reference;R=1kΩ,C=10nF) begin
    R1=resistor(input,output;value=R); C1=capacitor(output,reference;value=C)
end
@circuit DocsTwoStage begin
    gnd=ground(); input=node(); middle=node(); output=node()
    Source=voltage_source(input,gnd;ac=1V)
    First=DocsRCSection(input,middle,gnd;R=1kΩ,C=10nF)
    Second=DocsRCSection(middle,output,gnd;R=2kΩ,C=20nF)
    Load=resistor(output,gnd;value=100kΩ)
end
hierarchy=DocsTwoStage(); hierarchical_ac=small_signal(hierarchy,10Hz=>1MHz;source=:Source,points=21)
@assert voltage(hierarchical_ac,Symbol("First.output"))==voltage(hierarchical_ac,:middle)
@assert any(item->string(item.path)=="First.R1",devices(hierarchy;under="First"))

@circuit DocsFloating begin
    gnd=ground(); a=node(); b=node(); Reference=resistor(gnd,gnd;value=1kΩ)
    C1=capacitor(a,b;value=1nF)
end
@assert occursin("a, b",explain(DocsFloating()))

lookup_message=try
    voltage(op,:ouptut); ""
catch error
    sprint(showerror,error)
end
@assert occursin("Did you mean `output`?",lookup_message)

println("Validated the Quarto tutorial circuit examples.")
