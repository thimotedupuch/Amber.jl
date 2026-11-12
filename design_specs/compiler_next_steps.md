# Sequential compiler development

Work follows the twelve-item compiler investigation in order. Each item receives
its own implementation and validation checkpoint before the next begins. No
parallel compiler agents or production backend replacement are planned.

1. Constitutive-equation IR — experimental typed expression tree and symbolic
   derivatives and complete diode current/charge implemented; 329 targeted assertions pass. Existing handwritten batch
   kernels remain the production backend.
2. Fine-grained dependency analysis — experimental per-expression input sets,
   dependency roles and invalidation queries implemented; 22 assertions pass.
   Production cache integration remains pending.
3. Executable structural solve plans — pending.
4. Equation elimination and observable reconstruction — pending.
5. DAE structure and consistent initialization — pending.
6. Template symbolic compilation reuse — pending.
7. Bounded specialization and diversity benchmarks — pending.
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
