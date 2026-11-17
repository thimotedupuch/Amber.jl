using Amber, AmberSchematics

const OUTPUT = @__DIR__

# Evaluate only the Amber circuit declarations. The README also contains simulations.
function readme_circuits(names)
    remaining = Set(names)
    readme = read(joinpath(OUTPUT, "..", "..", "README.md"), String)
    for block in eachmatch(r"```julia\n(.*?)\n```"s, readme)
        occursin("@circuit ", block.captures[1]) || continue
        for expr in Meta.parseall(block.captures[1]).args
            expr isa Expr && expr.head === :macrocall && expr.args[1] === Symbol("@circuit") || continue
            declaration = expr.args[3]
            name = declaration isa Symbol ? declaration : declaration.args[1]
            name in remaining || continue
            Core.eval(@__MODULE__, expr)
            delete!(remaining, name)
        end
    end
    isempty(remaining) || error("Missing README circuits: $(join(sort!(collect(remaining)), ", "))")
end

readme_circuits((:LowPass, :StrainBridge, :NoisyFollower, :SmoothingRectifier, :LogicInverter))

function export_diagram(name, design, placements, labels, routing; symbols = Dict(), net_markers)
    # Query anchors from the same placed design used for export.
    layout = schematic(design; placements, labels, symbols)
    drawing = schematic(design; placements, labels, symbols, wires = routing(layout), net_markers)
    for ext in ("svg", "png")
        save_schematic(joinpath(OUTPUT, "$name.$ext"), drawing; theme = :dark)
    end
    println("Wrote ", name)
end

vertical(x, y) = Placement(x, y; rotation = 270)

function rail(layout, from, to, y)
    start, stop = anchor(layout, from...), anchor(layout, to...)
    points = [(start[1], y), (stop[1], y)]
    filter!(point -> point != start && point != stop, points)
    return Wire(from, to; via = unique!(points))
end

export_diagram("low_pass", LowPass(),
    Dict(:Source => vertical(0, 0), :R1 => Placement(2.25, 1.45), :C1 => vertical(4.5, 0)),
    Dict(:Source => "Source\n1 V DC / AC\n0–1 V step", :R1 => "R1\n10 kΩ", :C1 => "C1\n10 nF"),
    layout -> [
        rail(layout, (:Source, 1), (:R1, 1), 1.45),
        rail(layout, (:R1, 2), (:C1, 1), 1.45),
        rail(layout, (:Source, 2), (:C1, 2), -1.45),
    ]; net_markers = Dict(:vin => (0, 1.45), :vout => (4.5, 1.45), :gnd => (2.25, -1.45)))

export_diagram("strain_bridge", StrainBridge(),
    Dict(:Supply => vertical(0, 0), :Gauge => vertical(3, 1.45), :R2 => vertical(3, -1.45),
         :R3 => vertical(6, 1.45), :R4 => vertical(6, -1.45)),
    Dict(:Supply => "Supply\n5 V", :Gauge => "Gauge\n350.35 Ω", :R2 => "R2\n350 Ω",
         :R3 => "R3\n350 Ω", :R4 => "R4\n350 Ω"),
    layout -> [
        rail(layout, (:Supply, 1), (:Gauge, 1), 3),
        rail(layout, (:Gauge, 1), (:R3, 1), 3),
        Wire((:Gauge, 2), (:R2, 1)),
        Wire((:R3, 2), (:R4, 1)),
        rail(layout, (:Supply, 2), (:R2, 2), -3),
        rail(layout, (:R2, 2), (:R4, 2), -3),
    ]; net_markers = Dict(:excitation => (3, 3), :sense => (3, 0),
                          :reference => (6, 0), :gnd => (1.5, -3)))

export_diagram("follower", NoisyFollower(),
    Dict(:Source => vertical(-0.85, -0.75), :Buffer => Placement(3, 0), :Load => vertical(5.4, -1.5),
         :VDD => vertical(8, 0), :VSS => vertical(10.5, 0)),
    Dict(:Source => "Source\n1 V DC / AC", :Buffer => "Buffer", :Load => "Load\n10 kΩ",
         :VDD => "VDD\n+5 V", :VSS => "VSS\n−5 V"),
    layout -> [
        rail(layout, (:Source, 1), (:Buffer, 1), anchor(layout, :Buffer, 1)[2]),
        rail(layout, (:Buffer, 3), (:Load, 1), 0),
        Wire((:Buffer, 2), (:Load, 1); via = [(1.5, anchor(layout, :Buffer, 2)[2]),
             (1.5, -1.65), (4.8, -1.65), (4.8, 0), (5.4, 0)]),
        rail(layout, (:Source, 2), (:Load, 2), -3),
        rail(layout, (:Load, 2), (:VDD, 2), -3),
        rail(layout, (:VDD, 2), (:VSS, 2), -3),
    ]; net_markers = Dict(:input => (0.9, 0.27), :output => (4.8, 0), :gnd => (3, -3)))

export_diagram("rectifier", SmoothingRectifier(),
    Dict(:Source => vertical(0, 0), "D1.series_resistance" => Placement(2, 2),
         :D1 => Placement(4.5, 2), "C1.esr" => vertical(6.65, 0.55),
         :C1 => vertical(6.65, -1.75), :Load => vertical(9.4, -0.60)),
    Dict(:Source => "Source\n10 V peak · 50 Hz", "D1.series_resistance" => "D1 series resistance\n120 mΩ",
         :D1 => "D1", "C1.esr" => "C1 ESR\n180 mΩ", :C1 => "C1\n470 μF", :Load => "Load\n1 kΩ"),
    layout -> [
        rail(layout, (:Source, 1), ("D1.series_resistance", 1), 2),
        Wire(("D1.series_resistance", 2), (:D1, 1)),
        rail(layout, (:D1, 2), ("C1.esr", 1), 2),
        rail(layout, ("C1.esr", 1), (:Load, 1), 2),
        Wire(("C1.esr", 2), (:C1, 1)),
        rail(layout, (:Source, 2), (:C1, 2), -3.25),
        rail(layout, (:C1, 2), (:Load, 2), -3.25),
    ]; symbols = Dict(:Source => :sine_source, :C1 => :polarized_capacitor),
       net_markers = Dict(:input => (0, 2), :output => (6.65, 2), :gnd => (3.5, -3.25)))

export_diagram("cmos_inverter", LogicInverter(),
    Dict(:Input => vertical(-3.6, -1.35), :PullUp => Placement(0, 1.55), :PullDown => Placement(0, -1.55),
         :Load => vertical(2.7, -1.55), :VDD => vertical(5.0, 0.2)),
    Dict(:Input => "Input\n0–5 V sweep", :PullUp => "Pull-up\nPMOS", :PullDown => "Pull-down\nNMOS",
         :Load => "Load\n20 pF", :VDD => "VDD\n5 V"),
    layout -> [
        Wire((:PullUp, 2), (:PullDown, 2); via = [(-1.85, 1.55), (-1.85, -1.55)]),
        Wire((:Input, 1), (:PullDown, 2); via = [(-3.6, 0), (-1.85, 0), (-1.85, -1.55)]),
        Wire((:PullUp, 1), (:PullDown, 1)),
        rail(layout, (:PullUp, 1), (:Load, 1), 0),
        rail(layout, (:PullUp, 3), (:VDD, 1), 3.25),
        rail(layout, (:Input, 2), (:PullDown, 3), -3.25),
        rail(layout, (:PullDown, 3), (:Load, 2), -3.25),
        rail(layout, (:Load, 2), (:VDD, 2), -3.25),
    ]; symbols = Dict(:PullUp => :mos_logic, :PullDown => :mos_logic),
       net_markers = Dict(:input => (-2.55, 0), :output => (2.7, 0),
                          :supply => (2.7, 3.25), :gnd => (1.5, -3.25)))
