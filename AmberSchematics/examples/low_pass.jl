using Amber, AmberSchematics

@circuit LowPass() begin
    vin = node()
    vout = node()
    gnd = ground()
    V1 = voltage_source(vin, gnd; dc = 1)
    R1 = resistor(vin, vout; value = 1000)
    C1 = capacitor(vout, gnd; value = 1e-6)
end

drawing = schematic(LowPass();
    placements = Dict(
        :V1 => Placement(0, 0; rotation = 270),
        :R1 => Placement(2, 1.25),
        :C1 => Placement(4, 0; rotation = 270),
    ),
    labels = Dict(:V1 => "V1\n1 V", :R1 => "R1\n1 kΩ", :C1 => "C1\n1 μF"),
    wires = [
        Wire((:V1, 1), (:R1, 1); via = [(0, 1.25)]),
        Wire((:R1, 2), (:C1, 1); via = [(4, 1.25)]),
        Wire((:V1, 2), (:C1, 2); via = [(0, -1.25), (4, -1.25)]),
    ],
    net_markers = Dict(:vin => (0, 1.25), :vout => (4, 1.25), :gnd => (2, -1.25)),
)

save_schematic(isempty(ARGS) ? "low-pass.svg" : only(ARGS), drawing)
