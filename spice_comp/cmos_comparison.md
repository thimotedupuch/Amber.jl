# CMOS comparison and fixes

The transient interpretation is qualified by the later audit in
`cmos_transient_audit.md`: matched flags did not establish equal integration
accuracy, and the mutual waveform discrepancy was a one-sided sampled metric.

Julia 1.13.1, one thread; local pixi ngspice 41. This extends the preceding RC
comparisons to matched simplified MOS circuits, not foundry BSIM models.

## Model matching

Use Level-1 square-law NMOS/PMOS with threshold magnitudes 0.7 V, transconductance
2/1 mA/V², channel-length modulation 0.03/V, no body effect, and a 5 V supply.
ngspice W/L=1 matches Amber's effective transconductance. The bodies are tied to
the sources. Both run at 300 K with equal nominal temperature and explicit 10 pF
output capacitors. Amber's Level1 model has no intrinsic Meyer capacitance or
body diode, so ngspice uses TOX=1e6 and IS=1e-30 to suppress these contributions;
overlap and junction capacitances are zero. This deliberately matches the simple
Amber equations and is not a physically complete modern CMOS process model.

The bank contains independent identical inverters with shared supply and input.
DC/AC bias uses 2.5 V input. AC sweeps 101 linearly spaced frequencies from 1 kHz
to 100 MHz. Switching uses a 0–5 V input, 10 ns initial delay, 1 ns rise/fall,
100 ns period; Amber's duty includes the rise, matching ngspice's 49 ns pulse
width plus 1 ns rise. Transient duration is 210 ns unless otherwise stated.
Both use reltol=1e-6, current abstol=1e-12 A, voltage abstol=1e-9 V. ngspice
uses Gear order at most two; Amber uses BDF2 with exact waveform events. Fixed
and adaptive step handling remain different, so equal flags alone do not mean
equal accuracy. The refinement checks below quantify waveform agreement.

## Final warmed results

Each DC/AC timing is the minimum of three batches of ten analyses; ngspice runs
all ten inside one process, without waveform text output, and destroys each plot.
Amber warms the exact circuit and batch loop before timing. Both save all unknowns
and discard results between analyses. Table times are batch time divided by ten.

| Bank size | MOSFETs | Analysis | Amber | ngspice | Amber speedup |
| --- | ---: | --- | ---: | ---: | ---: |
| 1,000 | 2,000 | dc | 10.44 ms | 11.87 ms | 1.14x |
| 10,000 | 20,000 | dc | 130.97 ms | 928.80 ms | 7.09x |
| 1,000 | 2,000 | ac | 22.52 ms | 28.03 ms | 1.24x |
| 10,000 | 20,000 | ac | 257.61 ms | 1204.73 ms | 4.68x |

Switching remains slower in Amber. These times are per analysis, including
ordinary operating-point initialization in each simulator:

| Circuit | Max step | Amber | ngspice | ngspice speedup | Max waveform difference |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1-inverter bank | 62.500 ps | 68.69 ms | 10.25 ms | 6.70x | 9.815 mV |
| 100-inverter bank | 62.500 ps | 486.86 ms | 237.85 ms | 2.05x | 9.815 mV |
| 1-inverter bank | 15.625 ps | 253.11 ms | 37.24 ms | 6.80x | 0.607 mV |
| 10-inverter chain | 62.500 ps | 189.31 ms | 43.62 ms | 4.34x | 9.815 mV |

The ten-stage chain's final node traverses both rails. First and last output
waveforms are compared across the saved grid, interpolating ngspice's adaptive
samples. Coarse 250 ps single-inverter steps gave a 182 mV discrepancy and were
rejected for comparison. At 62.5 ps it is 9.82 mV; at 15.625 ps it drops to
0.607 mV, about 16x smaller. Even there ngspice is roughly 6.8x faster. This
shows a real remaining performance target, although a full equal-error-budget
comparison still requires independently varying each simulator's tolerances.

DC first/last output disagreement is below 4.4e-8 V. AC first/last full-grid
complex response disagreement is below 4.8e-6 at printed ngspice precision.
The AC optimization is additionally checked against the original matrix solve
for every unknown at every frequency to 1e-12.

## Fixes from the investigations

Two subagents investigated the switching and AC gaps independently.

1. Exact-event transient mode was running an auxiliary backward-Euler solve at
   every step even without state-controlled switches. Only real switch events
   now trigger this bracketing solve; prescribed waveform corners still bound
   the time grid. Single-inverter three-solve batches improve from 0.369 s to
   0.206 s (44%), with identical measured waveform error. Allocations drop from
   1.299 GB to 0.602 GB cumulatively per three solves. Genuine switch-event
   regression tests remain enabled.
2. AC matrices retained compiler-pattern entries that were exactly zero in both
   static and dynamic Jacobians at the bias point. Removing only those entries
   reduces unnecessary symbolic edges and numeric factorization work. Entries
   nonzero in either derivative, however tiny, remain; the shared pattern is
   fixed for the complete sweep. Explicit SuiteSparse settings stay respected.
   Direct before/after comparisons improve by 2.45–2.88x. At 1,000 inverters,
   this changes the earlier loss against ngspice into a modest win. Regressions
   cover tiny and dynamic-only entries, empty dimensions, all-state CMOS
   equivalence, and both SuiteSparse ordering options.
3. A 100-inverter chain initially failed during operating-point continuation
   when an intermediate Newton matrix became singular. LinearSolveError now
   rejects that continuation step and allows existing subdivision/fallback.
   The ordinary unseeded operating point recovers with alternating output
   rails and a checked residual. Genuinely singular circuits must still fail.
   The hundred-stage transient waveform and timing were not validated here.

## Scope and cold-start costs

The favorable large results are synthetic banks with repeated identical gates;
they should not be generalized to arbitrary logic networks or modern BSIM
transistors. Connected-chain evidence here covers ten switching stages and the
100-stage operating point only.

Construction, circuit compilation, and first analysis are recorded separately.
A 10,000-inverter bank takes about 9.8 s to construct and 0.25 s to compile in
Amber, excluded from the analysis table. The first DC analysis in the fresh
final process took 3.24 s and its first AC analysis 1.57 s; subsequent cases
share compiled code. These are not independent cold-start measurements.
ngspice startup and parsing remain inside its process timing, amortized over ten
analyses. No claim of a cold end-to-end win is made.

## Reproduce

```sh
pixi install --manifest-path spice_comp/pixi.toml
AMBER_SPICE_KINDS=dc,ac AMBER_SPICE_CELLS=1000,10000 AMBER_SPICE_REPEATS=10 julia --project=Amber benchmark/ngspice_cmos.jl
AMBER_SPICE_KINDS=transient AMBER_SPICE_CELLS=1,100 julia --project=Amber benchmark/ngspice_cmos.jl
AMBER_SPICE_KINDS=transient AMBER_SPICE_CELLS=1 AMBER_SPICE_STEP=1.5625e-11 AMBER_SPICE_REPEATS=1 julia --project=Amber benchmark/ngspice_cmos.jl
AMBER_SPICE_KINDS=transient AMBER_SPICE_TOPOLOGY=chain AMBER_SPICE_CELLS=10 AMBER_SPICE_REPEATS=1 julia --project=Amber benchmark/ngspice_cmos.jl
```

Raw files: `cmos_dc_ac_results.toml` (original bank baseline),
`cmos_ac_compaction_results.toml` (direct original/compact comparison),
`cmos_dc_ac_after_results.toml` (final ten-analysis batches),
`cmos_refinement_results.toml` (single-gate transient baseline),
`cmos_transient_after.toml`, `cmos_chains_refined.toml`, and
`cmos_chain_100_failure.txt` (original failure and recovery notes).

## Validation

The combined MOS, charge-based MOS, operating-point, transient, AC, network,
and noise run passed 379 checks and exposed one new test expecting the wrong
exception type for a floating circuit: validation correctly rejects it before
linear solving. After correcting that test to expect CircuitValidationError,
the complete operating-point suite passes 29/29, including the recovered
100-stage rail/residual checks and floating-circuit rejection. Thus all 380
checks in the selected suite are covered by successful runs after correction.
The full repository suite was not rerun for these changes. `git diff --check`
passes.
