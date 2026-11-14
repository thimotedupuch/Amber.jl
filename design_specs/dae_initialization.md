# DAE structure and consistent initialization

`dae_structure(circuit)` inspects evaluated storage-Jacobian incidence sparsely.
It excludes explicit zero padding and reports matching-based storage rank,
zero-storage equation rows and participating columns. For nonlinear models the
incidence is local to the supplied state, not a conservative union over all
possible states. A matching rank is not numerical rank: a two-terminal capacitor
can have matching rank two and numerical rank one.

`dae_structure(circuit; numerical=true)` equilibrates storage rows and columns,
then computes a size-bounded SVD (default at most 512 unknowns). It exposes the
singular values, independent left/right storage coordinates, algebraic constraint
combinations, and a local classification. This is not a general nonlinear
DAE-index proof or an index-reduction transformation.

## Linear initialization

`consistent_initial_conditions(circuit, guess; time=0, temperature=300)` supports
linear compiled device contracts. In scaled coordinates it preserves the right
storage coordinates of the guess, solves the left-nullspace algebraic
constraints, then determines a derivative from the differential equations and
differentiated algebraic constraints. Componentwise residual checks validate
both solves and the original continuous DAE equations.

The resulting `DAEInitialCondition` can initialize transient simulation. Analysis
descriptors accept it; completed results snapshot its numerical state into the
ordinary initial-vector representation and retain initialization diagnostics.
The object is bound to circuit parameters, time and temperature. A content digest
detects mutation of state/derivative vectors before use. Stochastic transient
initialization uses the same validation and snapshots.

Independent source derivatives are analytic for built-in smooth waveform
segments. At a waveform corner, an explicit equation-space `forcing_derivative`
is required; initialization does not silently approximate a discontinuity.
Unknown waveform types also require this derivative. Higher-index and
rank-ambiguous constraints are rejected rather than silently regularized.

## Regressions found during review

The first integration attempted to store the new object in the old restricted
`Transient.initial` field and failed during result construction. Initial-condition
markers now allow analysis descriptors to carry validated objects, while result
snapshots remain independent numerical vectors.

The initial rank threshold could discard a genuine small storage mode: two 1Ω
shunts, a 1F coupling capacitor and 1e-12F shunts retain a common-mode dynamic
coordinate that a 1e-10 relative cutoff would remove. The projected zero state
still satisfies residual checks, so a residual test cannot detect the lost
initial energy. Singular values between the roundoff floor and the requested
cutoff now yield `:rank_ambiguous`; initialization declines. An explicitly tighter
well-resolved tolerance retains the mode and preserves the requested state.
Modes below floating-point resolution remain inherently indistinguishable from
exact null modes; no exact structural-index claim is made.

## Boundaries

Numerical analysis is optional and dense-bounded; large circuits still have
sparse incidence inspection. Nonlinear initialization, constraint differentiation
for higher-index systems, and automatic index reduction are not implemented.
Raw vector and `:discharged` initialization preserve their existing semantics;
consistent initialization is opt-in. Numerical rank depends on scaling and the
explicit tolerance, and backward error does not guarantee forward accuracy in
ill-conditioned systems.

Validation checkpoint: 44 new assertions and 119 existing transient, noise and
periodic assertions pass. Review findings above have dedicated regressions.
