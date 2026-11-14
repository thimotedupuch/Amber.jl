# Sequential compiler development

Work follows the twelve-item compiler investigation in order. Each item receives
its own implementation and validation checkpoint before the next begins. No
parallel compiler implementations or default backend replacement are planned.

1. Constitutive-equation IR — experimental typed expression tree and symbolic
   derivatives and complete diode current/charge implemented; 329 targeted assertions pass. Existing handwritten batch
   kernels remain the production backend.
2. Fine-grained dependency analysis — experimental per-expression input sets,
   dependency roles and invalidation queries implemented; 22 assertions pass.
   Production cache integration remains pending.
3. Executable structural solve plans — implemented as an opt-in block linear
   executor and operating-point strategy; numerical compatibility checks and
   global fallback protect changed matrices. Block-local nonlinear iteration and
   factorization reuse remain future work.
4. Equation elimination and observable reconstruction — initial numerical affine
   reduction implemented with reversible substitutions and a linear-only DC
   entry point. General symbolic/DAE transformations remain pending.
5. DAE structure and consistent initialization — sparse storage inspection and
   bounded numerical analysis implemented; opt-in linear initialization preserves
   dynamic coordinates and solves state/derivative constraints. Higher-index and
   rank-ambiguous systems are explicitly declined.
6. Template symbolic compilation reuse — local connectivity/stamp/auxiliary
   plans reused across instances; optional bounded caller-owned cache supports
   repeated compilation without caching numerical bindings.
7. Bounded specialization and diversity benchmarks — configurable tuple/erased
   batch boundary implemented across numerical paths; dispatch contexts avoid
   per-batch argument boxing. Diversity/JIT/warm regressions are measured.
8. Derivative requests and shared intermediates — pending.
9. Parameter dependency graphs — pending.
10. Numerical cache dependency identities — pending.
11. Conflict-aware parallel assembly — pending.
12. Symbolic solve plans and typed backend workspaces — pending.

## Item 1: current implementation boundary

`src/Core/ConstitutiveIR.jl` provides internal, tuple-typed expression nodes,
lazy piecewise branches, symbolic first derivatives (also differentiable again
for supported expressions), local zero/one derivative simplification, input
incidence inspection, and a local current/charge kernel. No runtime `eval`,
new dependency, or per-instance code generation is required.

The diode prototype reproduces the existing conduction law including temperature,
linear/constant exponential continuations and avalanche onset. Model saturation
current is an explicit numerical input; diode geometry/model options remain
construction-time data. Independent reference device kernels and central
finite differences validate derivatives. Passive current/charge tests validate
both outputs and type inference.

This is a typed expression tree, not yet a shared SSA DAG: common-subexpression
elimination and global sparse lowering are not implemented. The experimental diode law now includes depletion and diffusion charge;
production simulation still uses the handwritten backend. Arbitrary external
callbacks, noise declarations, units in expressions, and a public modeling DSL
remain future work. Piecewise derivatives follow the selected branch and omit
impulse terms; switching boundaries require explicit treatment before automatic
transient lowering. No production device equations or solve ordering changed.

Charge validation covers logarithmic grading=1 and ordinary power-law depletion,
linear forward continuation, diffusion charge, first/second voltage derivatives,
and continuous DAE tangents. An independent two-node circuit comparison checks
global residual, Jacobian, storage and storage Jacobian across bias/temperature.

`benchmark/constitutive_ir.jl` compares equal output sets against handwritten
kernels and reports construction, first-call/JIT, warm time and allocations.
A local Julia 1.13.1 run measured zero warm allocations for both paths. The IR
did not establish a speed advantage; no production switch is justified yet.
Results are tiny-kernel local measurements, not whole-simulation predictions.
Next: common-subexpression sharing, bounded specialization, and more complete
branch-boundary qualification before production lowering.

Validation: 176 new constitutive-IR assertions and 132 existing compiler/
optimization regression assertions pass. `git diff --check` is clean.


## Item 2: dependency analysis boundary

`EquationDependencies.jl` tracks exact named inputs and a category bitmask per
current, charge, and derivative expression. Temperature-dependent linear-device
tests show state-dependent residuals with configuration-dependent Jacobians.
Piecewise predicates remain dependencies. Missing or unknown input roles raise
errors instead of silently permitting a stale cache. Exact-name invalidation
handles expressions with multiple dynamic categories; coarse stage labels are
inspection hints and must never replace full dependency sets in cache keys.

Production `DeviceDependencies` and existing numerical cache rules are unchanged.
Migrating built-in models requires complete IR coverage and cache-equivalence
regressions, including temperature/mode changes. This is not yet accomplished.

Latest validation: 351 combined IR/dependency assertions and 139 existing
compiler/device-reference assertions pass. The full package suite was not rerun
for this isolated experimental increment.


## Item 3: executable structural plans

`structural_solve_plan(circuit; mode=:dc)` turns equation matching and SCC order
into explicit equation and unknown permutations with block boundaries. Time
plans include storage incidence. `structural_solve(plan, matrix, rhs)` solves
blocks in dependency order, propagates solved contributions downstream, and
returns original-order unknowns plus numerical diagnostics. A coupled single
block bypasses permutation/extraction and uses the global configured LU policy.

Every execution checks the actual nonzero matrix, including parameter changes
and regularization absent from structural incidence. Incompatible matrices,
singular blocks, and unacceptable numerical backward errors trigger global
fallback; `fallback=:error` supports strict investigation. Global singularities
still propagate. Backward error measures residual quality, not forward error or
conditioning. Exact singular blocks cannot be repaired by a global solve of a
truly block-triangular matrix; fallback does not promise to cure singularity.

`operating_point(circuit; linear_plan=plan)` opts Newton's linear systems into
this strategy and records `stats[:linear_solve_history]`. Existing Newton damping,
continuation and convergence criteria remain in place. The default path retains
its symbolic/numeric factorization reuse. The experimental block executor does
not yet reuse factors, perform block-local nonlinear iterations, eliminate
unknowns, or change result/observable identities. Standalone execution supports
one vector RHS; numerical qualification targets Float64/ComplexF64 matrices
as used by the existing LU backend. Wider scalar types remain unsupported.

Validation includes randomly permuted triangular systems, coupled blocks,
complex coefficients, integer RHS promotion, parameter changes, storage-inclusive
Jacobians, singularity, incompatible regularization, numerical fallback, and
linear/nonlinear operating-point equivalence. Full-suite results are recorded
in the accompanying [regression study](structural_solve_regression_study.md).

The [benchmark driver](../benchmark/structural_solve_plan.jl) measures native
sparse solves separately from Amber's configured LU policy. It includes
validation/permutation/error-check components and end-to-end operating points.
The prototype's overhead and algorithm-selection differences are studied rather
than interpreted as a reason to replace the default backend.

Item 3 validation checkpoint: 60 targeted structural-plan assertions and the
full package suite (3,212/3,212) pass after the overflow fix. The independent
review found no further correctness issues. Benchmark data and limitations are
retained in the regression study; the strategy remains opt-in.


## Item 4: reversible affine reduction

`reduce_linear_system(A)` snapshots a numerical linear operator and eliminates
singleton/two-term equations, with per-step fill bounds, relative pivot screening,
and stronger-pivot preference at equal fill cost. Sparse column incidence tracks
affected rows. `reduction_rhs`, `reconstruct_solution`, and `solve_reduced`
preserve original equation/unknown identities and support repeated RHS values;
changing matrix coefficients requires rebuilding the plan.

`reduced_operating_point(circuit)` is an opt-in, linear-contract-only direct DC
entry point. It returns a normal result against the original compiled circuit,
so node voltages, source currents, component powers, and reporting use their
original definitions. Nonlinear models are rejected. Default solver and compiled
circuit layouts are unchanged.

Review found that a global normwise residual can hide errors in weak equations.
Acceptance now checks both normwise and componentwise backward error. The latter
uses per-row binary exponent scaling to avoid overflow and underflow. RHS
substitution overflow triggers global fallback before LU. Nonfinite matrix
updates stop plan construction without modifying the remaining operator.

This is a numerical operator transformation, not yet symbolic constitutive-IR
elimination. It does not transform storage laws, DAE constraints, AC feedthrough,
noise injections, or derivatives of reconstructed observables. Construction still
rescans candidate equations after each elimination; persistent candidate queues
and factorization reuse remain future work. See the
[regression study](linear_reduction_regression_study.md) for evidence and costs.

Item 4 validation checkpoint: 115 new assertions and 166 existing operating-point/
result/report/display assertions pass. Numerical regressions and performance
costs are recorded in the study. This remains an opt-in numerical transformation.

## Item 5: DAE inspection and consistent initialization

See [DAE initialization](dae_initialization.md) for the mathematical contract,
rank-ambiguity regression, descriptor integration and current boundaries.

## Item 6: template plan reuse

See [template plan reuse](template_plan_reuse.md) for key/ownership contracts,
historical baseline measurements, small-design overhead and validation.

## Item 7: bounded specialization

See [bounded specialization](bounded_specialization.md) for policy, dispatch
boundary design, inference/boxing regressions, measurements and validation.
