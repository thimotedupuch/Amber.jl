 ## What Amber can do today

  ### Small-signal frequency analysis

  Amber performs genuine bias-dependent AC linearization:

  [
  (G+j\omega C)\hat{x}=\hat{b}.
  ]

  It computes a DC operating point, extracts the static and dynamic Jacobians, and solves the sparse complex system at each frequency (src/Solvers/SmallSignal.jl:1).

  Consequently, it already supports:

  - Linear and nonlinear circuits linearized at their operating point.
  - Voltage and current excitation.
  - Linear or logarithmic frequency sweeps.
  - Complex node voltages, branch currents, internal states, and differential observables.
  - Voltage, current, transconductance, and transimpedance responses.
  - Controlled sources: VCVS, VCCS, CCVS, and CCCS.
  - Bias-dependent diode, BJT, MOSFET, switch, and behavioral op-amp responses, subject to their model fidelity.
  - AC current through capacitors and other derived observables.
  - Parameter sweeps and Monte Carlo analyses involving SmallSignal.
  - Comparison of two responses on the same frequency grid.
  - Magnitude and wrapped phase extraction.
  - Noise propagation through the same linearized system.

  The public surface is intentionally small: small_signal, frequencies, trace, transfer, magnitude, and phase (docs/src/manual/small-signal.md:1).

  Several useful analyses can therefore already be performed manually:

  - Filter gain and phase.
  - Amplifier bandwidth.
  - Resonance and Q by inspecting a response.
  - Input or output impedance by exciting a port and dividing voltage by current.
  - PSRR and CMRR by choosing the appropriate source and differential output.
  - Crosstalk and supply coupling.
  - Loop gain using a carefully constructed injection source.
  - Parameter-dependent bandwidth or resonance through sweeps.

  These are possible, but Amber does not yet make most of them first-class or protect the user from normalization and topology mistakes.

  ### Noise analysis

  Amber also has a valuable frequency-domain noise solver. It uses an adjoint solve per output and frequency, allowing multiple independent physical noise sources to be accumulated efficiently (src/Solvers/Noise.jl:58).

  Currently represented are:

  - Resistor thermal noise.
  - Diode shot noise.
  - BJT collector and base shot-noise approximations.
  - MOS channel thermal noise.
  - Output noise density.
  - Input-referred noise density.

  Important limitations are flicker noise, correlated sources, integrated RMS noise, and periodically time-varying noise. There is also a small documentation/implementation discrepancy: the manual says transfer-null warnings are produced, but the current calculation directly divides by gain without
  actually generating such a warning.

  ### Large-signal periodic and harmonic information

  Transient simulation supports sinusoidal and pulse excitation, exact prescribed switching events, and BDF integration. This makes it possible to simulate:

  - Oscillators.
  - Rectifiers.
  - Switching converters.
  - Sample-and-hold circuits.
  - Clipping and slew-induced distortion.
  - Startup into periodic operation.
  - Mixing and intermodulation, provided the time step and duration are chosen appropriately.

  periodic_metrics currently returns:

  - An estimated fundamental frequency.
  - Peak-based amplitude.
  - THD from harmonics 2 through 5.

  That implementation is deliberately elementary (src/Analysis/Metrics.jl:28). It uses zero crossings to estimate frequency and evaluates five Fourier components directly.

  ### Control-adjacent functionality

  Amber already has some time-domain metrics useful to control work:

  - Overshoot.
  - Propagation delay.
  - Peak-to-peak/ripple.
  - Periodic metrics.
  - Parameter sweeps.
  - Monte Carlo and yield calculations.

  Controlled sources also make classical analog feedback circuits straightforward to express. But Amber does not presently contain a control-theory analysis layer.

  ## What remains to be done

  ### 1. Complete the basic frequency-response API

  This should be the first priority because the solver already exists.

  Useful additions would be:

  - Explicit FrequencyResponse or enriched SmallSignalResult.
  - Arbitrary frequency vectors, rather than only low => high plus a point count.
  - db20, db10, unwrapped phase, group delay, and phase-delay utilities.
  - Interpolated cutoff and crossover detection.
  - Bandwidth, resonant frequency, Q, peaking, and notch depth.
  - Multiple named inputs and outputs in one analysis.
  - Clear normalization to the selected excitation.
  - Warnings for zero AC excitation, accidental multiple simultaneous sources, transfer nulls, and ill-conditioned solves.
  - Consistent complex AC amplitude and phase specification.
  - Integrated-noise calculations over arbitrary bands.

  At present source=nothing means all nonzero AC sources are combined, which is mathematically legitimate but easy to invoke accidentally (src/Core/Compilation.jl:219).

  ### 2. Make impedance and port analysis first-class

  This is probably the largest immediate “missing opportunity” for electronics users.

  A port abstraction could provide:

  - (Z_\text{in}), (Z_\text{out}), and transfer impedance.
  - Admittance.
  - Differential and common-mode ports.
  - Multiport (Z), (Y), (H), and ABCD matrices.
  - Source and load impedance handling.
  - S-parameters for RF and transmission-line work.
  - Stability-related source/load circles later, independently of plotting.

  Amber already has differential observables and everything needed to apply test sources. The important work is defining robust port orientation, excitation, normalization, and units.

  ### 3. Replace the minimal harmonic metric with a real spectrum API

  The present THD estimate is suitable as a convenience indicator, not yet as a measurement-quality harmonic analysis.

  A proper spectrum/harmonic_analysis layer should include:

  - Verification or resampling of adaptive/nonuniform transient output.
  - Window selection: rectangular, Hann, Blackman-Harris, flat-top, etc.
  - Coherent-sampling support.
  - Correct one-sided/two-sided amplitude, power, RMS, and PSD normalization.
  - DC, fundamental, harmonic table, phase, and per-harmonic power.
  - Configurable harmonic count rather than the fixed 2–5 range.
  - THD, THD+N, SINAD, SNR, SFDR, ENOB, and crest factor.
  - Automatic or specified fundamental frequency.
  - Interpolated spectral peaks.
  - Multi-tone IMD metrics such as IM2, IM3, IP2, and IP3.
  - Band-limited power and noise.
  - Aliasing and insufficient-record warnings.

  This can initially be implemented as transient post-processing; no new circuit solver is necessary.

  ### 4. Add periodic steady-state analysis

  Long transient warm-up is expensive and can be unreliable for high-Q or strongly separated time scales. A shooting-based periodic steady-state solver would be extremely useful for:

  - Switching converters.
  - Oscillators.
  - Chopper amplifiers.
  - Switched-capacitor circuits.
  - Sample-and-hold systems.
  - Mixers and modulators.

  A sensible progression would be:

  1. Fixed-period shooting PSS.
  2. Autonomous oscillator PSS with a phase condition.
  3. PSS sensitivity and convergence diagnostics.
  4. Periodic small-signal/PAC analysis.
  5. Periodic noise.
  6. Harmonic balance only after those pieces are mature.

  Harmonic balance is attractive, but PSS plus robust spectral post-processing would likely deliver value sooner and reuse more of Amber’s transient infrastructure.

  ### 5. Build the control-analysis layer

  For ordinary LTI circuits, the existing (G,C) pair is nearly the descriptor state-space model already. Amber should expose this through a documented linearization result rather than requiring access to internal Jacobians.

  High-value functions would include:

  - linearize(circuit; inputs, outputs).
  - Descriptor-system representation (E\dot{x}=Ax+Bu,\ y=Cx+Du).
  - MIMO frequency-response matrices.
  - Poles, zeros, natural frequencies, and damping ratios.
  - DC gain.
  - Stability classification.
  - Gain crossover and phase crossover.
  - Gain margin and phase margin.
  - Sensitivity (S), complementary sensitivity (T), and loop sensitivity.
  - Closed-loop bandwidth.
  - Step metrics: rise time, settling time, peak time, and steady-state error.
  - Root-locus data.
  - Export or optional interoperability with Julia control-system packages.

  Pole computation must preserve the descriptor nature of MNA. Simply inverting (C) is frequently impossible or numerically undesirable because circuit systems contain algebraic constraints and infinite generalized eigenvalues.

  ### 6. Support trustworthy loop-gain analysis

  Feedback-loop analysis deserves a dedicated implementation because casually “breaking the loop” can destroy the DC bias or alter loading.

  Amber could provide:

  - Middlebrook-style voltage or current injection.
  - Return-ratio/generalized loop-gain analysis.
  - Automatic preservation of DC bias.
  - Nested-loop selection.
  - Differential-loop support.
  - Impedance-ratio stability for converter input filters.
  - Disk margins eventually for MIMO systems.

  This would turn a currently possible but expert-only workflow into a safe and convenient one.

  ## Particularly valuable missing opportunities

  Beyond the obvious Bode/FFT features, these could distinguish Amber from a conventional lightweight SPICE interface:

  ### Frequency-domain sensitivities

  Compute derivatives such as

  [
  \frac{\partial H(j\omega)}{\partial p}
  ]

  for component and model parameters, preferably with adjoint methods. This enables:

  - Component influence ranking.
  - Tolerance allocation.
  - Frequency-dependent worst-case analysis.
  - Gradient-based filter and compensation design.
  - Monte Carlo acceleration.
  - Identification of which parasitic limits bandwidth or stability.

  ### Automated filter and resonance characterization

  Given an input and output, Amber could automatically classify and measure:

  - Low-pass, high-pass, band-pass, notch, or multi-resonant behavior.
  - Passbands and stopbands.
  - (-3\ \mathrm{dB}) points.
  - Ripple.
  - Q and damping.
  - Resonance splitting.
  - Group-delay flatness.

  These are useful even without plotting.

  ### Model fitting and reduced-order models

  Frequency responses could be fitted to rational models using vector fitting, followed by:

  - Pole/residue reporting.
  - Passivity checks.
  - Compact macromodel generation.
  - Reduced-order models for large RLGC networks.
  - Export into control workflows.

  This would be especially relevant once distributed or extracted interconnect models grow.

  ### Two-port and RF-oriented analysis

  Multiport matrices, mixed-mode conversion, S-parameters, stability factors, and noise figure would greatly broaden Amber’s applicability. Much of the underlying work overlaps with the proposed port abstraction and multi-input/output linearization.

  ### Frequency-aware verification

  Amber could automatically compare:

  - AC response against a small-amplitude transient sine measurement.
  - Extracted poles against transient decay.
  - Integrated PSD against time-domain RMS where applicable.
  - Results across frequency-grid refinement.
  - Energy/passivity properties of passive networks.

  This aligns particularly well with Amber’s current emphasis on transparent, verifiable numerics.

  ## Recommended order

  I would prioritize the work as follows:

  1. Harden and enrich SmallSignal: arbitrary grids, dB, unwrapped phase, group delay, bandwidth/crossover metrics, better excitation semantics and diagnostics.
  2. Add ports and first-class impedance/admittance/transfer measurements.
  3. Implement robust transient spectrum and harmonic metrics.
  4. Expose descriptor linearization and add poles, zeros, damping, and stability margins.
  5. Add safe loop-gain/return-ratio analysis.
  6. Add integrated noise, flicker noise, and correlation handling.
  7. Implement shooting PSS, then periodic AC/noise.
  8. Consider harmonic balance, multiport RF analysis, sensitivities, and model reduction.

  In short: Amber already has credible LTI small-signal frequency analysis, useful noise propagation, and a rudimentary transient harmonic metric. The most important near-term opportunity is to expose the mathematics it already computes as ports, frequency-response measurements, descriptor linear
  models, and control metrics. PSS and advanced harmonic methods are the major solver-level additions after that.
