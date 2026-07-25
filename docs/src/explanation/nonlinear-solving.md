# Nonlinear solving

At each Newton iteration Amber solves

```math
J(x_k)\,\Delta x=-F(x_k),\qquad x_{k+1}=x_k+\Delta x.
```

Voltage, current, and state magnitudes can differ by many orders, so Amber scales rows and unknowns before assessing convergence and solving the sparse linear system. Device limiting and continuation strategies reduce the chance that exponential models take numerically destructive steps.

Convergence requires both a small residual and a small update under absolute and relative tolerances. Tightening only one tolerance can produce misleading behavior. A converged root is one mathematical solution at one initial guess; circuits with multiple stable equilibria require deliberate initialization or continuation to explore other roots.

If Newton fails, inspect topology and scales first. More iterations rarely fix a structurally singular circuit. Record tolerance and continuation changes because they are part of the experiment.

