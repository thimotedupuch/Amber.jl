# AmberSchematics

Generate circuit diagrams from a finished Amber design. The same design supplies the simulator and the schematic, so you can check terminal indices and nets before exporting an SVG, PDF, or PNG. CairoMakie renders the diagram headlessly.

From the Amber repository root, install the companion package into your active Julia environment.

```julia
using Pkg
Pkg.develop(path = ".")
Pkg.develop(path = "AmberSchematics")
```

```julia
using Amber, AmberSchematics

@circuit LowPass() begin
    input = node(); output = node(); gnd = ground()
    V = voltage_source(input, gnd; dc = 1)
    R = resistor(input, output; value = 1000)
    C = capacitor(output, gnd; value = 1e-6)
end

design = LowPass()
drawing = schematic(design)
save_schematic("low-pass-overview.svg", drawing)
```

## Refine a diagram

Start with `connectivity(drawing)`. Each row identifies a component, its terminal index and pin name, and the Amber net and ground status. Use those identifiers to place symbols and route selected nets. Rotation is counterclockwise in 90° increments. Use `anchor(drawing, :R, 2)` to get the endpoint in drawing coordinates. Rebuild the drawing after editing the placements or routes.

```julia
placements = Dict(
    :V => Placement(0, 0; rotation = 270),
    :R => Placement(3, 2),
    :C => Placement(6, 0; rotation = 270),
)
drawing = schematic(design; placements, labels = Dict(:R => "R  1 kΩ", :C => "C  1 μF"),
    wires = [
        Wire((:V, 1), (:R, 1); via = [(0, 2)]),
        Wire((:R, 2), (:C, 1); via = [(6, 2)]),
    ])
save_schematic("low-pass.svg", drawing)
```

Use a newline in a component label to set its reference above its value, for example `"R1\n1 kΩ"`. The first line is bold and subsequent lines use smaller type.

The [complete low-pass example](examples/low_pass.jl) also routes the ground return and uses `net_markers` to place signal labels and a ground symbol on their conductors.

Routes must use horizontal and vertical segments. The package rejects routes between distinct Amber nets and detects touching or crossing conductors on distinct nets. A completely wired signal net can be read from its wires. Partially routed nets retain their Amber names at the terminal stubs. Ground retains its stub labels unless it is fully routed and has a ground marker. Layout changes have no effect on electrical behavior. The renderer measures text and adjusts external labels to clear symbols, wires, and other labels. Multiline captions move as a group. In dense custom layouts, review the resulting label positions before publishing.

The diagram represents the top-level design before solver compilation. Amber may already have expanded device packages or catalog components into primitives during circuit construction, and those primitives can appear in the diagram. Subcircuit instances appear as blocks with named ports. Sixteen Amber primitive kinds have dedicated symbols, with visual variants for common drawing conventions and device markings. Other primitives appear as blocks with their kind and terminal indices. Layout is a grid by default. Automatic wire routing, subcircuit expansion views, and automatic value labels are outside this release.

## What the Schemdraw reference informed

- Schemdraw's symbol catalog, named anchors, and cursor-relative placement make it quick to draw a circuit whose visual topology the author already knows. Its SVG backend and optional Matplotlib renderer make it practical for documentation.
- In the local reference, `Drawing.add` places the next element using the preceding cursor position and angle. Explicit coordinates and anchors can override that behavior. Cursor-dependent layouts can shift when an earlier element changes. AmberSchematics uses placements keyed by component and routes keyed by terminal, so agents can revise the diagram without editing a sequence of cursor commands.
- Schemdraw serializes drawing elements and placement parameters. Its electrical drawing primitives do not check the diagram against an Amber circuit or provide an Amber net identity for each terminal. AmberSchematics derives connections from the design and checks proposed wire endpoints against it. A named-net overview can be exported before any manual routing.
- Schemdraw also serves logic, flow, and timing diagrams and has a much larger symbol catalog. AmberSchematics starts with circuit documentation and uses CairoMakie for the same headless export formats available to AmberMakie users.

## Symbol library

The library covers passives, independent and controlled sources, diodes,
NPN transistors, four-terminal NMOS and PMOS, op-amps with supply pins,
and voltage-controlled switches. Pin names in `connectivity` follow Amber's
constructor order. Symbol rotation carries the pins with the geometry.

Choose compatible variants with `symbols`, keyed by component name.

```julia
drawing = schematic(design; symbols = Dict(
    :R1 => :iec_resistor, :C1 => :polarized_capacitor, :D1 => :led,
))
```

| Amber kind | Visual variants |
| --- | --- |
| Resistor or conductance | `:iec_resistor`, `:variable_resistor` |
| Capacitor | `:polarized_capacitor`, `:variable_capacitor` |
| Diode | `:zener`, `:schottky`, `:led`, `:photodiode` |
| Voltage source | `:sine_source` |
| NMOS or PMOS | `:mos_body_tied`, `:mos_logic` |

The first terminal of a polarized capacitor carries the positive mark.
Variants change the drawing only. Use the corresponding Amber model to
represent electrical behavior. Some catalog devices are expanded into several
primitives during construction, so the top-level view draws those primitives
individually.

MOSFETs default to the four-terminal symbol with a visible bulk terminal.
Use `:mos_body_tied` to show the tie inside the symbol, or `:mos_logic` to
use three visible terminals and a bubble on the PMOS gate. Both compact
styles require Amber's source and bulk to share a net. The bulk retains its
original terminal index in `connectivity` and shares the source's anchor.

Pass `theme = :dark` to `figure` or `save_schematic` for a dark background
and a matching wire, symbol, and label palette.

## More examples

- [Five-stage RC ladder](examples/rc_ladder.jl) builds a repeated circuit and routes its shared return.
- [CMOS inverter](examples/cmos_inverter.jl) uses four-terminal MOSFET symbols with explicit source-to-body ties.
- [Symbol library sheet](examples/symbol_library.jl) renders every supported symbol and visual variant.
