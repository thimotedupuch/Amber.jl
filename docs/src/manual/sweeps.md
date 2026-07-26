# Parameter sweeps

`sweep` repeats an analysis while varying a selected parameter. Sweeps are valuable for sensitivity studies and response surfaces; unlike Monte Carlo, sample points are deliberately chosen.

Parameter paths use stable component names. Build and validate the nominal circuit first, keep analysis settings fixed across points, and preserve failed points rather than silently dropping them.

For small custom studies, ordinary Julia is equally expressive:

```@example sweep_manual
using Amber
function divider(rbottom)
    c = Circuit(:divider)
    top = node!(c, :top)
    out = node!(c, :out)
    gnd = ground!(c)
    add!(c, voltage_source(top, gnd; dc=1.0); name=:v)
    add!(c, resistor(top, out; value=1kΩ); name=:rt)
    add!(c, resistor(out, gnd; value=rbottom); name=:rb)
    observe!(c, voltage(out))
    voltage(operating_point(c), :out)[1]
end

[divider(r) for r in (500.0, 1kΩ, 2kΩ)]
```

Prefer logarithmic grids for behavior spanning decades. Around discontinuities or bifurcations, refine the grid and inspect full solutions rather than interpolating blindly.
