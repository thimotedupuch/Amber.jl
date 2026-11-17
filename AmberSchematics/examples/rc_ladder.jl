using Amber, AmberSchematics

function rc_ladder()
    builder = CircuitBuilder(:rc_ladder)
    vin = node!(builder, :vin)
    gnd = ground!(builder)
    add!(builder, voltage_source(vin, gnd; dc = 1); name = :V1)

    stages = 5
    pitch = 2.55
    rail = 1.35
    placements = Dict(:V1 => Placement(0, 0; rotation = 270))
    labels = Dict(:V1 => "V1\n1 V")
    wires = Wire[]
    net_markers = Dict(:vin => (0.0, rail), :vout => (stages * pitch, rail),
                       :gnd => (2.5 * pitch, -rail))

    previous_net = vin
    previous_signal = (:V1, 1)
    previous_return = (:V1, 2)
    for stage in 1:stages
        net = node!(builder, stage == stages ? :vout : Symbol("tap", stage))
        resistor_name, capacitor_name = Symbol("R", stage), Symbol("C", stage)
        add!(builder, resistor(previous_net, net; value = 1000); name = resistor_name)
        add!(builder, capacitor(net, gnd; value = 100e-9); name = capacitor_name)

        x = stage * pitch
        previous_x = (stage - 1) * pitch
        placements[resistor_name] = Placement((stage - 0.5) * pitch, rail)
        placements[capacitor_name] = Placement(x, 0; rotation = 270)
        labels[resistor_name] = "R$stage\n1 kΩ"
        labels[capacitor_name] = "C$stage\n100 nF"

        push!(wires, Wire(previous_signal, (resistor_name, 1); via = [(previous_x, rail)]))
        push!(wires, Wire((resistor_name, 2), (capacitor_name, 1); via = [(x, rail)]))
        push!(wires, Wire(previous_return, (capacitor_name, 2);
            via = [(previous_x, -rail), (x, -rail)]))

        previous_net = net
        previous_signal = (capacitor_name, 1)
        previous_return = (capacitor_name, 2)
    end

    return schematic(finish(builder); placements, labels, wires, net_markers)
end

save_schematic(isempty(ARGS) ? "rc-ladder.svg" : only(ARGS), rc_ladder())
