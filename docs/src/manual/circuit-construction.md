# Circuit construction

An Amber circuit is a graph whose vertices are electrical nodes and whose edges are components. Construction is explicit: create a circuit, name its nodes, then add components.

```@example construction
using Amber

c = CircuitBuilder(:loaded_divider)
vdd = node!(c, :vdd)
out = node!(c, :out)
gnd = ground!(c)
add!(c, voltage_source(vdd, gnd; dc=12.0); name=:supply)
add!(c, resistor(vdd, out; value=10e3); name=:upper)
add!(c, resistor(out, gnd; value=10e3); name=:lower)
add!(c, resistor(out, gnd; value=10e3); name=:load)
observe!(c, voltage(out))
design = finish(c)
check(design)
```

Names are part of the model, not decoration. They make diagnostics, parameter paths, saved circuits, and result tables intelligible. Amber uniquifies repeated node names; explicit unique names remain clearest.

`@circuit` offers a compact surface while producing the same immutable `CircuitDesign`. Prefer `CircuitBuilder` in reusable libraries where ordinary Julia control flow and helper functions are clearer; call `finish` once construction is complete.

Call `check(design)` before a long analysis, `describe(design)` to inspect the assembled model, and `compile(design)` when repeated analyses should reuse topology work. Finished designs are immutable, and numerical changes use copy-on-write `with_parameters` updates.

Every connected problem needs a reference node. `ground!(c)` creates or returns it. Two-terminal devices use ordered positive and negative terminals; current and voltage signs follow that order. See [Sign conventions](@ref).

A component changes the equations. An observable asks Amber to retain or derive a quantity. Add observables before simulation with `observe!`; use `voltage`, `current`, `power`, `charge`, or `state` to construct them.
