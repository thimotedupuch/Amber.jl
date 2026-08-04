# Nonlinear solving

At each Newton iteration Amber solves

```math
J(x_k)\,\Delta x=-F(x_k),\qquad x_{k+1}=x_k+\Delta x.
```

Voltage, current, and state magnitudes can differ by many orders, so Amber scales rows and unknowns when solving the sparse linear system. Exponential models retain a finite restoring slope outside their safe evaluation range, and operating-point continuation automatically bisects a source/gmin step when a full step fails.

Regenerative circuits can contain a fold where the branch followed by ordinary source/gmin continuation ceases to exist. If adaptive subdivision reaches such a fold, Amber retries the full-source problem with pseudo-transient continuation. This adds a temporary conductance referenced to the preceding iterate, follows the circuit's dissipative trajectory toward a stable state, and removes the conductance for the final Newton solve. The selected path is reported as `result.stats[:strategy]`.

Convergence requires both a small residual and a small Newton update under absolute and relative tolerances. The update check is essential for high-impedance nodes: their KCL error can be below the absolute current tolerance while their voltage is still wrong by volts. Tightening only one tolerance can produce misleading behavior. A converged root is one mathematical solution at one initial guess; circuits with multiple stable equilibria require deliberate initialization or continuation to explore other roots.

If Newton fails, inspect topology and scales first. More iterations rarely fix a structurally singular circuit. Record tolerance and continuation changes because they are part of the experiment.
