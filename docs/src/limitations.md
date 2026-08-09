# Current limitations

Amber is an early-stage simulator with a deliberately compact scope.

> **TO REWRITE:** Re-audit this list against the retained hierarchy and current compiled APIs.

- MOSFETs use a transparent level-1 model, not BSIM or foundry-qualified model cards; subthreshold, body-diode, junction-charge, and short-channel effects are absent.
- Semiconductor models are educational/engineering compact models, not foundry-qualified libraries.
- Behavioral op-amp slew-rate and output-current-limit fields are not fully enforced.
- Noise models are limited by Amber's compact device equations; in particular,
  the level-1 MOSFET has no body diode, substrate network, or foundry-calibrated
  BSIM noise model.
- Stochastic transient noise uses a fixed grid, and power-law noise requires
  explicit finite low- and high-frequency limits.
- Periodic and phase-noise accuracy depends on PSS convergence, orbit sampling,
  and harmonic-sideband truncation.
- Temperature dependence is limited; electrothermal and self-heating effects are absent.
- Switch charge injection is modeled only for specific prescribed control transitions.
- Hierarchy is flattened through Julia composition rather than retained as nested instances.
- Serialization cannot encode arbitrary Julia functions or unknown user device types.
- There is no SPICE netlist importer/exporter or external simulator parity suite.
- Multiple equilibria, very stiff systems, ideal constraint loops, and extreme scale separation may require careful initialization and refinement.

These boundaries are not reasons to distrust every result; they define what evidence a result needs. Prefer circuits with inspectable theory, report solver metadata, test sensitivity to numerical settings, and avoid claims outside model scope.
