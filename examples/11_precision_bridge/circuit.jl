using Amber

"""Wheatstone strain bridge followed by a three-op-amp instrumentation amplifier."""
@circuit PrecisionBridge(;resistance=1kΩ,strain=500e-6,gain_resistance=1kΩ) begin
    gnd=ground(); positive_rail=node(); negative_rail=node(); excitation=node()
    bridge_positive=node(); bridge_negative=node(); first_output=node(); second_output=node()
    first_feedback=node(); second_feedback=node(); difference_positive=node(); difference_negative=node(); output=node()
    PositiveSupply=voltage_source(positive_rail,gnd;dc=5V)
    NegativeSupply=voltage_source(gnd,negative_rail;dc=5V)
    Excitation=voltage_source(excitation,gnd;dc=2.5V)
    Rbridge1=resistor(excitation,bridge_positive;value=resistance*(1+strain),tolerance=.001)
    Rbridge2=resistor(bridge_positive,gnd;value=resistance,tolerance=.001)
    Rbridge3=resistor(excitation,bridge_negative;value=resistance,tolerance=.001)
    Rbridge4=resistor(bridge_negative,gnd;value=resistance,tolerance=.001)
    A1=opamp(bridge_positive,first_feedback,first_output,positive_rail,negative_rail)
    A2=opamp(bridge_negative,second_feedback,second_output,positive_rail,negative_rail)
    Rfeedback1=resistor(first_output,first_feedback;value=10kΩ,tolerance=.0001)
    Rfeedback2=resistor(second_output,second_feedback;value=10kΩ,tolerance=.0001)
    Rgain=resistor(first_feedback,second_feedback;value=gain_resistance,tolerance=.0001)
    RinNegative=resistor(first_output,difference_negative;value=10kΩ)
    RinPositive=resistor(second_output,difference_positive;value=10kΩ)
    Rreference=resistor(difference_positive,gnd;value=10kΩ)
    Difference=opamp(difference_positive,difference_negative,output,positive_rail,negative_rail)
    RdifferenceFeedback=resistor(output,difference_negative;value=10kΩ)
    Load=resistor(output,gnd;value=100kΩ)
    observe(voltage(bridge_positive,bridge_negative),voltage(output))
end
