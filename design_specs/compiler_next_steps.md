# Sequential compiler development

Work follows the twelve-item compiler investigation in order. Each item receives
its own implementation and validation checkpoint before the next begins. No
parallel compiler agents or production backend replacement are planned.

1. Constitutive-equation IR — experimental typed expression tree and symbolic
   derivatives implemented; 176 targeted assertions pass. Existing handwritten batch
   kernels remain the production backend.
2. Fine-grained dependency analysis — pending.
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
elimination and global sparse lowering are not implemented. Diode depletion and
diffusion charge still use the production handwritten code. Arbitrary external
callbacks, noise declarations, units in expressions, and a public modeling DSL
remain future work. Piecewise derivatives follow the selected branch and omit
impulse terms; switching boundaries require explicit treatment before automatic
transient lowering. No production device equations or solve ordering changed.

Before replacing a batch kernel: extend the law to complete diode charge;
compare f, q, first/second derivatives and assembled circuit residuals across
bias/temperature regions; measure cold compilation, warm evaluation and
allocations against the existing batch implementation. Keep the backend opt-in
until those checks establish correctness and acceptable cost.

Validation: 176 new constitutive-IR assertions and 132 existing compiler/
optimization regression assertions pass. `git diff --check` is clean.
