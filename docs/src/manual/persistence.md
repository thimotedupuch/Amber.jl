# Persistence and reproducibility

Amber serializes circuits and Monte Carlo results to versioned, deterministic TOML representations. Prefer `save_circuit`/`load_circuit` and `save_monte_carlo`/`load_monte_carlo` for files; use the corresponding `serialize_…` and `deserialize_…` methods for strings.

```@example persistence
using Amber
c = Circuit(:saved_divider)
v, o = node!(c, :v), node!(c, :o); g = ground!(c)
add!(c, voltage_source(v, g; dc=3.0); name=:source)
add!(c, resistor(v, o; value=1kΩ); name=:r1)
add!(c, resistor(o, g; value=2kΩ); name=:r2)
text = serialize_circuit(c)
restored = deserialize_circuit(text)
voltage(operating_point(restored), :o)[1]
```

The format is for Amber data interchange, review, and reproducible experiments. It is not a SPICE netlist and cannot encode arbitrary Julia closures. Unsupported user-defined models or callbacks must be reconstructed in code. Version tags permit explicit compatibility decisions instead of best-effort guessing.

For durable studies, preserve Amber and Julia versions, source revision, input artifact, solver settings, and result provenance together.
