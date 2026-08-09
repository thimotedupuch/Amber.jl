using Amber

"""Conductance crossbar followed by one transimpedance amplifier per output row."""
function ConductanceCrossbar(;conductances=[2.0 1.0 0.5; 0.5 1.5 2.0].*μS,
        inputs=[0.2,0.5,0.8].*V,feedback_resistance=100kΩ)
    rows,columns=size(conductances)
    length(inputs)==columns||throw(ArgumentError("one input voltage is required per crossbar column"))
    all(>=(0),conductances)||throw(ArgumentError("physical conductances must be nonnegative"))

    c=CircuitBuilder(:ConductanceCrossbar)
    gnd=ground!(c,:gnd)
    positive_rail=node!(c,:positive_rail)
    negative_rail=node!(c,:negative_rail)
    input_nodes=[node!(c,Symbol(:input_,column)) for column in 1:columns]
    summing_nodes=[node!(c,Symbol(:summing_,row)) for row in 1:rows]
    output_nodes=[node!(c,Symbol(:output_,row)) for row in 1:rows]

    add!(c,voltage_source(positive_rail,gnd;dc=5V);name=:PositiveSupply)
    add!(c,voltage_source(gnd,negative_rail;dc=5V);name=:NegativeSupply)
    for column in 1:columns
        add!(c,voltage_source(input_nodes[column],gnd;dc=inputs[column]);
            name=Symbol(:Input_,column))
    end

    # Each device is explicit so that loading and crosspoint nonidealities remain
    # part of the circuit. Rows terminate at TIA virtual-ground summing nodes.
    for row in 1:rows, column in 1:columns
        add!(c,conductance(input_nodes[column],summing_nodes[row];
            value=conductances[row,column]);name=Symbol(:G_,row,:_,column))
    end
    for row in 1:rows
        add!(c,opamp(gnd,summing_nodes[row],output_nodes[row],positive_rail,negative_rail;
            model=BehavioralOpAmp(dc_gain=120dB,gain_bandwidth=10MHz,
                output_resistance=1Ω));name=Symbol(:TIA_,row))
        add!(c,resistor(output_nodes[row],summing_nodes[row];value=feedback_resistance);
            name=Symbol(:Rfeedback_,row))
        observe!(c,voltage(output_nodes[row]);name=Symbol(:output_,row))
    end
    finish(c)
end
