# Circuit construction

An Amber circuit is a graph whose vertices are electrical nodes and whose edges are components. Construction is explicit: create a circuit, name its nodes, then add components.

```@example construction
using Amber
 c = Circuit(:loaded_divider)
vdd = node!(c, :vdd); out = node!(c, :out); gnd = ground!(c)
add!(c, voltage_source(vdd, gnd; dc=12.0); name=:supply)
add!(c, resistor(vdd, out; value=10e3); name=:upper)
add!(c, resistor(out, gnd; value=10e3); name=:lower)
add!(c, resistor(out, gnd; value=10e3); name=:load)
observe!(c, voltage(out))
check(c)
```

Names are part of the model, not decoration. They make diagnostics, parameter paths, saved circuits, and result tables intelligible. Amber uniquifies repeated node names; explicit unique names remain clearest.

`@circuit` offers a compact surface for scripts while producing the same `Circuit` object. Prefer the explicit API in reusable libraries where ordinary Julia control flow and helper functions are clearer.

Call `check(c)` before a long analysis, `describe(c)` to inspect the assembled model, and `compile(c)` when repeated analyses should reuse topology work. Compilation freezes a private copy, so later edits to the source circuit cannot silently alter a compiled model.

Every connected problem needs a reference node. `ground!(c)` creates or returns it. Two-terminal devices use ordered positive and negative terminals; current and voltage signs follow that order. See [Sign conventions](@ref).

A component changes the equations. An observable asks Amber to retain or derive a quantity. Add observables before simulation with `observe!`; use `voltage`, `current`, `power`, `charge`, or `state` to construct them.
