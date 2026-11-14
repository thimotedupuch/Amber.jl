# Numerical cache dependency identities

Constant G/E buffers now use an exact, process-local coefficient identity rather
than a content digest as the correctness key. Numerical updates retain that
identity only when the fields actually consumed by constant kernels compare
equal. Source forcing changes retain it; resistor, capacitor and controlled
source coefficient changes replace it. Unknown linear contracts conservatively
compare all parameters. Digests remain useful provenance, not proof of equality.

The identity covers both G and E. This deliberately permits conservative
invalidation (a storage-only change can invalidate a DC factorization). It does
not yet compute the smallest possible cache dependency set for every analysis.
Direct mutation of compiled parameter arrays is unsupported: updates must use
`with_parameters` so identity and derived-parameter propagation stay coherent.

Newton's numerical factor key includes topology identity, coefficient identity,
integration coefficient, mode, gmin and solver policy. A separate exact snapshot
of variable scales detects even direct edits of workspace scaling vectors. This
adds O(n) comparison on attempted reuse and one vector per workspace; it closes
a stale-factor bug rather than claiming a speed improvement. Invalid zero or
nonfinite scales fail before assembly.

Workspaces also bind to the original topology object. A numerically updated
circuit shares that topology and can reuse the workspace; a separately compiled
circuit requires its own workspace, even if its dimensions happen to match.
This protects sparse slot indices from accidental cross-circuit reuse.

Tests cover RHS-only numerical factor reuse, nonuniform scaling changes,
coefficient changes for controlled sources, a deliberately colliding digest,
and wrong-topology rejection. The coefficient declarations describe the
handwritten constant kernels; experimental expression dependencies remain a
separate, finer-grained inspection API.
