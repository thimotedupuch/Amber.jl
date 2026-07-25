# Sign conventions

Amber uses the passive sign convention. For a two-terminal component declared from `p` to `n`,

```math
v = V(p)-V(n), \qquad i>0\ \text{flows from }p\text{ to }n,
```

and ``p=vi`` is positive when the component absorbs power. A voltage source delivering power therefore commonly reports negative power. Reversing an observable's nodes reverses its voltage sign but does not alter the circuit.

Controlled sources document their output and control orientations separately. BJT terminal currents are positive into the device. Make orientation explicit in names such as `v_base_emitter` or `i_supply_delivered` when a report could otherwise be ambiguous.

