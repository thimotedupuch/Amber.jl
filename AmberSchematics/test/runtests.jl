using Amber
using AmberSchematics
using Test

@subcircuit Load(input, reference) begin
    R = resistor(input, reference; value = 1000)
end

@circuit Filter() begin
    input = node(); output = node(); gnd = ground()
    V = voltage_source(input, gnd; dc = 1)
    R = resistor(input, output; value = 1000)
    C = capacitor(output, gnd; value = 1e-6)
    X = Load(output, gnd)
end

@testset "Amber topology and Cairo export" begin
    design = Filter()
    drawing = schematic(design)
    rows = connectivity(drawing)
    net(device, terminal) = only(row.net for row in rows if
        row.device == device && row.terminal == terminal)
    @test net("V", 1) == net("R", 1)
    @test net("R", 2) == net("C", 1) == net("X", 1)
    @test net("X", 2) == net("V", 2)
    @test only(row.pin for row in rows if row.device == "X" && row.terminal == 1) == "input"
    @test !any(row -> row.device == "X.R", rows)

    placements = Dict(:V => Placement(0, 0), :R => Placement(4, 0),
        :C => Placement(8, 0; rotation = 90), :X => Placement(0, -4))
    routed = schematic(design; placements, wires = [Wire((:V, 1), (:R, 1);
        via = [(-2, 0), (-2, 2), (2, 2), (2, 0)])])
    @test length(schematic(design; placements, net_markers = Dict(
        :input => (-1.05, 0))).markers) == 1
    @test_throws ArgumentError schematic(design; net_markers = Dict(:input => (100, 100)))
    @test anchor(routed, :R, 1) == (2.95, 0)
    @test anchor(routed, :C, 1) == (8, -1.05)
    @test_throws ArgumentError schematic(design; wires = [Wire((:V, 2), (:R, 1))])
    @test_throws ArgumentError schematic(design; placements = Dict(:typo => Placement(0, 0)))
    @test_throws ArgumentError schematic(design; placements, wires = [
        Wire((:V, 1), (:R, 1))])
    mktempdir() do directory
        for (extension, signature) in (("svg", "<svg"), ("pdf", "%PDF"), ("png", "\x89PNG"))
            path = joinpath(directory, "filter.$extension")
            @test save_schematic(path, routed) == path
            bytes = read(path)
            @test extension == "svg" ? occursin(signature, String(bytes)) :
                bytes[1:ncodeunits(signature)] == collect(codeunits(signature))
        end
    end
end

@testset "Opt-in rendering compaction" begin
    placements = Dict(:V => Placement(0, 0), :R => Placement(18, 0),
        :C => Placement(32, 0), :X => Placement(0, -12))
    drawing = schematic(Filter(); placements, wires = [Wire((:V, 1), (:R, 1);
        via = [(-2, 0), (-2, 3), (12, 3), (12, 0)])],
        net_markers = Dict(:gnd => (1.05, 0)))
    routes = deepcopy(drawing.routes)
    terminals = connectivity(drawing)
    original = size(figure(drawing).scene)
    compact = size(figure(drawing; compact = true).scene)
    @test all(compact .< original)
    @test size(figure(drawing; compact = false).scene) == original
    @test drawing.routes == routes
    @test connectivity(drawing) == terminals
    @test anchor(drawing, :R, 1) == (16.95, 0.0)
    mktempdir() do directory
        path = joinpath(directory, "compact.svg")
        @test save_schematic(path, drawing; compact = true, check_layout = true) == path
        @test occursin("<svg", read(path, String))
    end
end

@testset "Ground marker clearance" begin
    design = Filter()
    marker = Dict(:gnd => (1.05, 0.0))
    placements = Dict(:V => Placement(0, 0), :R => Placement(4, 0),
        :C => Placement(8, 0), :X => Placement(0, -4))
    drawing = schematic(design; net_markers = marker, placements)
    @test length(drawing.markers) == 1
    @test figure(drawing) isa AmberSchematics.CM.Figure
    @test_throws ArgumentError schematic(design; net_markers = marker,
        placements = merge(placements, Dict(:R => Placement(2.10, -0.39))))
    @test_throws ArgumentError schematic(design; net_markers = marker,
        placements = merge(placements, Dict(:R => Placement(1.66, -0.70))))
end

@testset "Symbol pin order and compatible variants" begin
    builder = CircuitBuilder(:symbols)
    p = node!(builder, :p)
    n = node!(builder, :n)
    out = node!(builder, :out)
    supply = node!(builder, :supply)
    gnd = ground!(builder)
    add!(builder, opamp(p, n, out, supply, gnd); name = :U)
    add!(builder, diode(out, gnd); name = :D)
    add!(builder, pmos(out, p, supply, supply); name = :M)
    design = finish(builder)
    drawing = schematic(design; symbols = Dict(:D => :led))
    rows = connectivity(drawing)
    @test [(row.pin, row.net) for row in rows if row.device == "U"] ==
        [("IN+", "p"), ("IN−", "n"), ("OUT", "out"), ("V+", "supply"), ("V−", "gnd")]
    @test [(row.pin, row.net) for row in rows if row.device == "M"] ==
        [("D", "out"), ("G", "p"), ("S", "supply"), ("B", "supply")]
    @test anchor(drawing, :U, 4)[2] > anchor(drawing, :U, 5)[2]
    @test anchor(drawing, :M, 1)[2] < anchor(drawing, :M, 3)[2]
    @test rows == connectivity(schematic(design))
    @test_throws ArgumentError schematic(design; symbols = Dict(:D => :polarized_capacitor))
end

@testset "Diamond symmetry and label clearance" begin
    for radius in (0.38, 0.39)
        diamond = AmberSchematics._diamond((0.22, 0.0), radius)
        @test diamond[1] == diamond[end]
        @test first(extrema(first, diamond)) ≈ 0.22 - radius
        @test last(extrema(first, diamond)) ≈ 0.22 + radius
        @test extrema(last, diamond) == (-radius, radius)
    end

    label = (at = (0.0, 0.0), value = "Reference", align = (:center, :bottom),
        size = 14, color = :black, font = :bold)
    value = merge(label, (at = (0.0, -0.22), value = "10 kΩ", font = :regular))
    obstacles = [AmberSchematics._path_box(((-2.0, 0.0), (2.0, 0.0)))]
    placed = AmberSchematics._label_positions([([label, value], (0.0, 1.0))], obstacles)
    @test placed[2].at[2] > 0.0
    @test placed[1].at[2] - placed[2].at[2] ≈ 0.22
    @test !AmberSchematics._boxes_overlap(obstacles[1], obstacles[3])
    @test_throws ArgumentError AmberSchematics._check_label_clearance(
        [label, label], [obstacles[2], obstacles[2]])
end

@testset "MOS variants and dark export" begin
    builder = CircuitBuilder(:mos_styles)
    d = node!(builder, :d)
    g = node!(builder, :g)
    s = node!(builder, :s)
    b = node!(builder, :b)
    add!(builder, pmos(d, g, s, s); name = :P)
    add!(builder, nmos(d, g, s, b); name = :N)
    design = finish(builder)
    standard = schematic(design)
    @test anchor(standard, :P, 3) != anchor(standard, :P, 4)
    for variant in (:mos_body_tied, :mos_logic)
        drawing = schematic(design; symbols = Dict(:P => variant))
        @test anchor(drawing, :P, 3) == anchor(drawing, :P, 4)
        @test connectivity(drawing) == connectivity(standard)
        @test_throws ArgumentError schematic(design; symbols = Dict(:N => variant))
    end
    mktempdir() do directory
        path = joinpath(directory, "dark.svg")
        save_schematic(path, standard; theme = :dark)
        exported = read(path, String)
        @test occursin("<svg", exported)
        @test !occursin("fill:rgb(100%, 100%, 100%)", exported)
    end
    @test_throws ArgumentError figure(standard; theme = :unknown)
end
