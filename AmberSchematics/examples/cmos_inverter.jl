using Amber, AmberSchematics

@circuit Inverter() begin
    vin = node(); vout = node(); vdd = node(); gnd = ground()
    M1 = pmos(vout, vin, vdd, vdd)
    M2 = nmos(vout, vin, gnd, gnd)
    CL = capacitor(vout, gnd; value = 20e-12)
end

drawing = schematic(Inverter();
    placements = Dict(:M1 => Placement(0, 1.5), :M2 => Placement(0, -1.5),
                      :CL => Placement(3, -1.5; rotation = 270)),
    labels = Dict(:M1 => "M1\nPMOS", :M2 => "M2\nNMOS", :CL => "Cₗ\n20 pF"),
    wires = [
        Wire((:M1, 2), (:M2, 2); via = [(-1.8, 1.5), (-1.8, -1.5)]),
        Wire((:M1, 1), (:M2, 1)),
        Wire((:M1, 1), (:CL, 1); via = [(0.25, 0), (3, 0)]),
        Wire((:M1, 3), (:M1, 4); via = [(0.25, 3), (1.45, 3), (1.45, 1.5)]),
        Wire((:M2, 3), (:M2, 4); via = [(0.25, -3), (1.45, -3), (1.45, -1.5)]),
        Wire((:M2, 3), (:CL, 2); via = [(0.25, -3), (3, -3)]),
    ],
    net_markers = Dict(:vin => (-1.8, 0), :vout => (3, 0), :vdd => (0.8, 3), :gnd => (1.8, -3)),
)

save_schematic(isempty(ARGS) ? "cmos-inverter.svg" : only(ARGS), drawing)
