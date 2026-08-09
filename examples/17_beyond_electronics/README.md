# Beyond electronics

These executable examples use circuit analogies to solve five nontraditional
problems with Amber's normal compiled transient solver:

- `hodgkin_huxley.jl`: the four-state Hodgkin--Huxley membrane equations;
- `thermal.jl`: bidirectionally coupled electrical resistance and thermal flow;
- `loudspeaker_waveguide.jl`: a lumped driver and acoustic transmission line;
- `sir.jl`: nonlinear SIR population flow;
- `josephson_junction.jl`: normalized RCSJ Josephson phase dynamics.

The state-equation examples use `behavioral_current_source`. A capacitor turns
KCL into an ODE: with `C = 1`, a source current `-f(x,t)` produces `dx/dt=f(x,t)`.
Every source also supplies its analytic control gradient, so it participates in
the same sparse Newton iterations as physical devices.

These are compact educational models. The loudspeaker uses a one-dimensional
lumped waveguide, the neuron is space-clamped, the thermal example omits spatial
radiation, and the Josephson example is normalized rather than a quantum-circuit
or noise model.
