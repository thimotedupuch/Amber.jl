# Transient integration

Backward differentiation formulas replace ``\dot{x}`` with an implicit finite difference, converting every time point into a nonlinear algebraic solve. BDF1 is robust and dissipative. BDF2 is more accurate for smooth trajectories but needs history and careful handling after discontinuities.

Adaptive integration estimates local error and accepts or rejects a trial step. Known source transitions and requested output times are inserted as exact breakpoints. After a discontinuity, order or step size may be reduced because the smoothness assumptions behind higher order no longer hold.

Three convergence studies answer different questions: decrease solver tolerances, decrease maximum step, and compare integration order. For switching problems also align measurements to physical periods. Numerical convergence does not imply that idealized instantaneous switching represents real hardware.

