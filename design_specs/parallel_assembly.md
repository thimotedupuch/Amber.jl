# Conflict-aware assembly

`parallel_assembly_plan(cc; chunk_size=256)` computes dependency waves over
contiguous device ranges. Each chunk declares residual rows and sparse Jacobian
slots conservatively from compiled stamping metadata. A chunk is placed after
every earlier writer of any of its locations. Within a wave writes are disjoint;
across waves accumulation order at each location matches serial batch assembly.
Ordinary graph coloring would prevent simultaneous writes but could change
floating-point reduction order, so it is insufficient here.

`parallel_residual_jacobian!` executes the existing continuous residual/Jacobian
kernels using these ranges. It accepts `threaded=false` for scheduled serial
qualification. It is opt-in; Newton and discrete charge-history assembly retain
their existing paths. No per-thread full matrix buffers or atomic sums are used.

Behavioral callbacks, independent sources (including arbitrary user waveforms),
and unknown future batch kinds are serial barriers. Builtin pure device laws may
run concurrently. Each barrier follows all earlier work and precedes all later
work, preserving callback order and avoiding concurrent invocation of user code.
The plan binds to topology identity and can be reused with numerical updates.
Plans and compiled stamping metadata must not be mutated during execution.
Each task owns its numerical workspace; concurrent use of the same workspace is
unsupported. Input/output aliases are rejected before buffers are cleared.

Dense overlap yields serial waves and task launch overhead can exceed device
work. Chunk size is an explicit policy; this prototype does not select an
automatic threshold or claim speed improvements. Validation requires exact
serial equality with multiple Julia threads, storage terms and gmin.

The same 512-node fixture measured serial assembly at 1.49 microseconds / 64
bytes, scheduled serial at 2.20 microseconds / 3,616 bytes, and four-thread
assembly at 12.55 microseconds / 20,272 bytes (21 warm samples, median). Source
callbacks are conservatively barriers; resistor chunks of 32 devices provide
parallel waves. Task scheduling and dynamic chunk dispatch dominate these tiny
kernels. This approximately 8.4x slowdown is an explicit opt-in cost, not a
production regression: the default assembly path remains serial. Larger kernels,
work estimates and persistent worker scheduling need separate qualification
before automatic selection would be justified. The driver and raw data are
`benchmark/solve_ownership.jl` and `measurements/solve_ownership.toml`.
