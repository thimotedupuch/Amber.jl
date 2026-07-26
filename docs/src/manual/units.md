# Units

Amber solves entirely in SI units. Exported unit names are numeric scale factors, so expressions remain ordinary Julia numbers:

```@example units
using Amber
r = 4.7kΩ
c = 100nF
τ = r * c
(r, c, τ)
```

This syntax improves readability but does not provide dimensional type checking. `10V + 2s` is valid Julia even though it is physically meaningless. Treat suffixes as conversion constants, not as a units package.

Every supported SI unit provides `f`, `p`, `n`, `μ`, `m`, `k`, `M`, `G`, and
`T` prefixes. Electrical and time units include `Ω`, `V`, `A`, `F`, `H`, `C`,
`S`, `s`, and `Hz`; temperature uses `K`. Length uses `m`, with conventional
prefixed names such as `mm`, `μm`, and `km`. For example, both `4.7mS` and
`22μH` are ordinary numeric expressions.

A bare number already means SI. At API boundaries, document the expected
dimension even when the argument name seems obvious.
