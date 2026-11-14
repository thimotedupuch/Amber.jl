# Symbolic solve metadata and typed numerical ownership

`compiled_solve_plan(cc)` snapshots sparse column/row indices and default
variable scales and binds them to topology identity. A plan also carries the
linear solver policy and can include the existing structural block plan with
`structural=true`. Numerical parameter updates can reuse this metadata.
`SimulationWorkspace(plan)` allocates independent numerical matrices, scaling
vectors and solver state. All CSC index arrays are copied: one workspace cannot
change another workspace's sparse structure. Plan arrays are read-only by
contract and must not be mutated while workspaces are constructed or used.

The workspace is parameterized by scalar type, concrete UMFPACK factor type and
plan type. Its factorization and key fields are small `Union{Nothing,T}` values,
replacing `Any`. The key explicitly identifies topology, coefficients,
integration coefficient, mode, regularization and policy. Each task owns its LU
and buffers. Sharing symbolic metadata does not make numerical workspaces
thread-safe. The supported numerical factor backend remains SuiteSparse LU;
this increment does not pretend arbitrary backends satisfy its storage contract.

Newton can take defaults from its workspace plan. Public analysis solver options
remain explicit overrides. Structural block plans are consumed by the existing
qualified block executor. Policy changes now construct a fresh LU rather than
passing a new ordering/pivot policy to a numeric refactorization which would
retain the previous controls. Unchanged policies retain symbolic reuse.

This separation is an ownership and inference improvement. It adds metadata
snapshot/copy costs during default workspace construction and makes no claim of
warm solve speedup. It does not serialize backend factors or share UMFPACK
symbolic handles across tasks. Such handles require a backend-specific lifetime
and concurrency contract before reuse can be safe.

The reproducible `benchmark/solve_ownership.jl` driver measures construction and
assembly separately. Raw local Julia 1.13.1/four-thread data are in
`measurements/solve_ownership.toml`. For 512 independent source/resistor nodes,
default workspace construction measured 15.26 microseconds / 155,960 bytes;
reusing a supplied plan measured 11.67 microseconds / 142,976 bytes. This compares
two current ownership APIs, not a historical pre-change baseline. The extra
metadata snapshot in default construction has measurable allocation cost;
callers building many task workspaces can reuse a plan explicitly.
