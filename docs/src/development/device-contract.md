# Device contract

A device extension must define terminals, structural unknowns/states, DC and dynamic residual contributions, matching Jacobian entries, observable extraction, validation, and serialization policy where supported.

Residual and Jacobian formulas must agree. Test them with finite differences at ordinary and extreme operating points. Declare every possible sparse entry during topology construction; numerical assembly may change values but not invent a new location. State orientation and current sign must follow [Sign conventions](@ref).

For dynamic charge ``q(v)``, stamp the derivative consistently so transient and AC see the same differential capacitance. A model with discontinuities must expose event times or use a smooth transition appropriate to Newton iteration. Add validity warnings for physical regimes where equations remain solvable but cease to be meaningful.

An extension is complete only with analytic tests, serialization decisions, public docstrings, and a manual description of its physical scope.

