# Generalized modified nodal analysis

Amber writes circuit equations as a differential-algebraic residual

```math
F(x,\dot{x},t)=0.
```

The unknown vector contains non-ground node voltages plus branch currents and internal states required by elements that cannot be represented by nodal conductance alone. Kirchhoff current equations occupy node rows; voltage constraints and device state equations occupy the remaining rows.

Each device contributes local residual and Jacobian entries. This stamping contract permits linear, nonlinear, dynamic, and controlled devices to share one assembly path. DC sets time derivatives to zero. Transient discretizes them. AC linearizes both static and dynamic terms around a DC point.

Generalized MNA is powerful, but ideal constraints can create singular systems. Two conflicting ideal voltage sources, an unconstrained floating subnetwork, or redundant state equations are modeling errors that no linear solver can repair.

