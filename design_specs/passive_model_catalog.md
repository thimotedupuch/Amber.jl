# Materials, packages, and device models

This inventory separates reusable physical models from component constructors.
Technology names identify a family; they do not select a manufacturer part or
supply measured coefficients. All new noise, loss, and package parameters default
to zero. Supply values from a datasheet or measurement for the intended part.

## Inventory before this expansion

| Layer | Available API | Implemented behavior and limits |
|---|---|---|
| Resistor material | `ThinFilm` | Power-law excess current noise in addition to resistor thermal noise. Nonzero `tc1`, `temperature_coefficient`, and `voltage_coefficient` are rejected. |
| Passive package | `SMD0603` | Resistor series inductance and terminal shunt capacitance; capacitor ESR and ESL. Zero parasitics by default. |
| Capacitor dielectric | `C0G` | Lossless marker; nonzero loss tangent was rejected. |
| Dielectric absorption | `DebyeBranches` | Explicit series RC branches in parallel with the main capacitor. |
| Ideal value wrappers | `IdealResistor`, `IdealCapacitor` | Nominal resistance/capacitance wrappers. |
| Junction | `JunctionDiode` | Junction conduction, series resistance, depletion/diffusion charge, reverse breakdown, shot and flicker noise. |
| Bipolar transistor | `GummelPoonBJT` | NPN transport, Early effect, base resistance, junction capacitances, shot/flicker noise; nonzero transit time rejected. |
| MOS | `Level1MOSFET`, `ChargeBasedMOSFET` | Level-1 channel/static capacitances or charge-based terminal storage and temperature dependence; thermal/flicker and optional correlated gate noise. |
| Amplifier | `BehavioralOpAmp` | Finite gain/bandwidth, output resistance, input offset/bias/capacitance, voltage/current noise; slew rate, output current limit, and recovery settings restricted to neutral values. |
| Switch | `VoltageControlledSwitch`, `EventSwitch`, `SmoothSwitch` | On/off or smooth conductance, charge injection and clock feedthrough. |
| Waveforms | `Step`, `Sine`, `Pulse` | Source time dependence. |
| Matching and observations | `MatchedGroup`, `matched_group`, `Differential` | Matching parameter records and differential signal references. |

Existing component constructors, included for completeness:

- Passives: `resistor`, `capacitor`, `inductor`, `conductance`.
- Sources: `voltage_source`, `current_source`, `transconductance`,
  `voltage_controlled_voltage_source`, `current_controlled_current_source`,
  `current_controlled_voltage_source`, `behavioral_current_source`,
  `behavioral_voltage_source`.
- Semiconductors and active elements: `diode`, `npn`, `nmos`, `pmos`, `opamp`,
  `analog_switch`, `zener`, `schottky`, `led`, `photodiode`, `solar_cell`,
  `njfet`, `pjfet`.
- Composites and behavioral helpers: `analog_multiplier`, `voltage_limiter`,
  `comparator`, `voltage_controlled_resistor`, `varistor`, `thermistor`,
  `potentiometer`, `ideal_transformer`, `bridge_rectifier`, `crystal`,
  `transmission_line`.

Inductors already accept winding resistance and parallel capacitance directly.
Capacitors already accept ESR, ESL, leakage resistance, and dielectric absorption
directly. These effects do not require a named technology.

## Prioritized additions implemented here

Priority reflects how many existing circuits can use an addition and whether its
behavior can be represented consistently by the existing solver primitives.

| Priority | Additions | Relevance and behavior |
|---|---|---|
| 1 | `PassivePackage`, `SMD0201`, `SMD0402`, `SMD0805`, `SMD1206`, `SMD1210`, `SMD2010`, `SMD2512`, `Axial`, `Radial` | Reusable configurations for small-signal, power, and leaded passives, alongside existing `SMD0603`. Explicit lumped parasitics; SMD names use imperial size codes. |
| 2 | `ThickFilm`, `MetalFilm`, `CarbonFilm`, `CarbonComposition`, `MetalFoil`, `Wirewound` | Common resistor technologies, alongside `ThinFilm`. All use the existing configurable power-law excess-noise model. |
| 3 | `X7R`, `X5R`, `Polypropylene`, `Polyester`, `PPS`, `Mica`, `AluminumElectrolytic`, `Tantalum` | Ceramic, film, precision, and bulk capacitor families. These and `C0G` now support explicitly calibrated loss. |

All 24 new types support `model_parameters`, `with_model_parameter`, circuit
serialization, and result provenance. Numerical parameters are validated on
construction, model copying, and deserialization. Model names retain their
identity across serialization. Equal parameters give equal electrical behavior
across technology names; family-specific empirical defaults are deliberately
absent.

### Packages

```julia
package = SMD0402(series_inductance=0.4nH, parallel_capacitance=20fF)
R1 = resistor(a, b; value=10kΩ, package)
C1 = capacitor(a, b; value=1μF, package=Radial(esr=0.2Ω, esl=5nH))
```

These are illustrative values. Every package accepts the same four fields:

- Resistors use `series_inductance` in series with the resistance and
  `parallel_capacitance` across the external terminals.
- Capacitors use `esr` and `esl` in series. Component-level `esr` and `esl`
  override the corresponding package values, including when explicitly zero.

Nonzero fields belonging to the other component kind are rejected when adding a component. Package names do not
infer layout, mounting, geometry, voltage rating, thermal resistance, or inductor
core behavior. An empty package leaves the ideal component unchanged.

### Resistor materials

```julia
material = ThickFilm(
    excess_noise_coefficient=1e-12,
    excess_current_exponent=2.,
    excess_frequency_exponent=1.,
    excess_reference_frequency=1Hz,
)
R1 = resistor(a, b; value=10kΩ, material)
```

The excess current-noise PSD is
`coefficient * abs(I)^current_exponent * (reference_frequency/f)^frequency_exponent`.
It adds to Johnson noise. Coefficient units depend on the chosen current exponent.
All coefficients/exponents are finite and nonnegative, and the reference
frequency is positive. No technology name implies a particular noise level.
Wirewound inductance must be specified through the package.

Temperature and voltage coefficients remain explicitly unsupported for every
resistor material. The README demonstrator has been corrected accordingly.

### Capacitor dielectrics and loss

```julia
C1 = capacitor(a, b; value=10nF,
    dielectric=C0G(loss_tangent=1e-4, reference_frequency=1kHz),
    package=SMD0805(esr=30mΩ, esl=500pH),
    dielectric_absorption=DebyeBranches(
        time_constants=[1μs, 1ms], fractions=[0.002, 0.001]),
)
```

A nonzero tangent requires an explicit positive `reference_frequency` in Hz.
The builder computes a constant series resistance
`Rloss = loss_tangent / (2π * reference_frequency * nominal_capacitance)` and adds
it to the component/package ESR. This follows the series-equivalent dissipation
factor relation described in [KYOCERA AVX's capacitor application guide](https://www.kyocera-avx.com/docs/techinfo/TechSumAppGuide.pdf).

This is a single-frequency calibration, not constant loss tangent over a sweep.
The calibration describes the nominal capacitor alone; ESL, leakage, absorption,
and extra ESR change the combined terminal dissipation factor. It produces the
same physical RC model in DC, AC, transient, and noise analyses, including thermal
noise from the loss resistance. If a datasheet ESR already includes dielectric
loss, use that ESR alone to avoid counting the loss twice.

The class labels do not model DC-bias derating, aging, temperature curves,
polarization, voltage limits, or failure. Use explicit leakage and absorption
parameters where needed. Debye capacitances are *additional* to nominal C:
`Ci = C * fraction[i]`, `Ri = time_constant[i] / Ci`. Fractions must be finite and
nonnegative; time constants must be finite and positive. Zero fractions add no
branch.

Physical details are expanded when building the circuit. Use a fresh circuit
construction for technology/geometry changes. `with_parameters` rejects package,
dielectric, and absorption replacement; use `with_model_parameter` on a standalone
model and rebuild. Updating a compiled capacitor's `value` changes the main
capacitance only; the already-expanded loss resistor and absorption branches stay
fixed. Rebuild to preserve the specified loss calibration or absorption fractions.

## Next priorities requiring additional physical kernels

These are a follow-on roadmap, beyond the implemented catalog above:

1. **Resistor temperature and voltage dependence.** Restore the original
   demonstrator with a constitutive resistance law, analytic Jacobian, consistent
   thermal/excess noise, and temperature-sweep reference tests.
2. **Capacitor bias/temperature/aging curves.** Particularly relevant to X7R/X5R;
   require charge-based storage and measured curves, rather than a fixed
   capacitance multiplier that mishandles differential capacitance.
3. **Inductor core materials.** Air-core, ferrite, and powdered-iron models with
   saturation, core loss, and eventually hysteresis; require flux/state and
   energy-conservation tests.
4. **Electrothermal packages.** Thermal resistance/capacitance networks and
   self-heating, linked consistently to temperature-sensitive device equations.
5. **Measured broadband models.** Frequency-dependent conductor/dielectric loss,
   skin effect, and fitted passive networks with causal transient behavior.

These additions need new model behavior and reference validation; introducing
technology names alone would not implement them.
