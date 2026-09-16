# Component keyword audit

Component keywords are checked against the implemented primitive contracts in
`src/Devices/Ideal.jl`. Model constructors separately check their named parameters.
A parameter can legitimately affect only one analysis, or require another effect
to be enabled (for example, a flicker exponent with nonzero flicker coefficient).

| Component family | Where parameters affect simulation |
| --- | --- |
| Resistor, conductance | `value` enters the conductance matrix and thermal noise. Resistor material parameters control excess noise; resistor package inductance and capacitance create additional elements. |
| Capacitor | `value` enters charge and the dynamic matrix. `initial_voltage` sets transient initial conditions. ESR, ESL, leakage, dielectric loss, and Debye absorption create additional elements, including their thermal noise. Explicit ESR/ESL override package values, including zero. |
| Inductor | `value` enters the branch flux equation. Winding/series resistance and parallel capacitance create additional elements. Only one resistance alias may be supplied. |
| Statistical keywords | Passive `tolerance` draws relative variations of `value` for Monte Carlo simulations. NPN `match` applies correlated saturation-current and beta variations from a `MatchedGroup`. |
| Independent sources | `dc` supplies operating-point excitation; `ac` supplies complex small-signal excitation. A waveform replaces DC excitation in transient analysis. Voltage-source series resistance enters the branch equation and thermal noise. |
| Controlled sources | Gain, transconductance, or transresistance enters the residual and Jacobian. Current controls resolve to branch unknowns at compilation. |
| Behavioral sources | The value callback supplies the residual; the gradient callback supplies its voltage derivatives. Control count is internal metadata derived from the supplied controls. |
| Diode | Junction and breakdown parameters enter conduction; depletion and transit-time parameters enter charge; noise parameters enter shot/excess noise. Series resistance creates an additional resistor. |
| BJT | Transport, beta, and Early parameters enter conduction; junction capacitances enter charge; noise parameters enter shot/excess noise. Base resistance creates an additional resistor. Nonzero transit time remains explicitly unsupported. |
| Level-1 MOSFET | Threshold, transconductance, channel-length modulation, and body effect enter channel current; gate capacitances enter charge; noise coefficients enter channel, gate, and flicker noise. |
| Charge-based MOSFET | Geometry and temperature coefficients enter current and charge; overlap, area, and perimeter enter terminal/junction charge and junction current; noise parameters enter noise sources. Instance geometry overrides update the model before compilation. |
| Op-amp | Gain, bandwidth, offset, and output resistance enter the internal pole/output equations; noise parameters enter input/output noise. Input capacitance and bias currents create additional elements. Finite slew/current limits and nonzero saturation recovery remain explicitly unsupported. |
| Switch | Threshold, on/off resistance, and smooth transition enter conductance. Clock feedthrough creates a capacitor. Charge injection applies on falling switching events in transient analysis. |
| Catalogue components | Junction wrappers pass their model parameters to diodes. Optical current, shunt resistance, potentiometer position, transformer ratio, crystal RLC, and line RLGC/section count lower to primitive elements. Multiplier, limiter/comparator, controlled resistor, varistor, and JFET parameters enter behavioral value/gradient laws. Thermistor temperature parameters determine its fixed resistance. |

## Silent omissions now rejected

- Unknown component keywords, including misspellings and parameters supplied at
  component level that belong inside `model=...`.
- Nonzero capacitor-only package fields on resistors, and resistor-only package
  fields on capacitors. Package fields are documented per component; they are
  not automatically interpreted as aliases.
- Wrong types for material, package, dielectric, and dielectric absorption.
- Invalid parasitic values that previously skipped elaboration, and simultaneous
  inductor resistance aliases that previously ignored one value.
- Compiled updates to elaborated model effects, including whole-model replacement.
  Changing an existing parasitic's value also requires rebuilding because it lives
  in a separate primitive. Capacitor value updates also require rebuilding when
  nonzero dielectric loss or absorption derives extra elements from that value.
  Current-control references likewise require recompilation.

The existing restrictions on resistor temperature/voltage coefficients and on
unsupported BJT/op-amp effects remain in place. Initial inductor current is not
implemented as a component keyword and is now rejected instead of ignored.

Regression coverage lives in `test/Devices/keywords.jl`; the passive catalogue
suite checks package/dielectric behavior against analytical AC and noise results.
The other device and solver suites cover current, charge, transients, and noise.
