# Devices and models

Amber separates convenient device constructors from physical model values. Constructors such as `resistor`, `diode`, `npn`, `nmos`, `pmos`, `opamp`, and `analog_switch` connect terminals and accept either direct parameters or a model object.

- `JunctionDiode` implements exponential junction current, optional breakdown, series resistance, depletion/transit charge, separated carrier shot noise, and optional power-law noise.
- `GummelPoonBJT` provides a compact NPN model with forward/reverse transport, Early effect, junction capacitances, base resistance, transport shot noise, and base-current power-law noise.
- `Level1MOSFET` provides symmetric NMOS and PMOS channel equations with body effect, triode and saturation regions, channel-length modulation, fixed intrinsic gate capacitances, channel/gate noise, correlation, and power-law noise.
- `ChargeBasedMOSFET` provides continuous inversion, explicit geometry, conserving terminal charges and temperature laws. See [Charge-based MOSFET](@ref).
- `BehavioralOpAmp` models finite open-loop gain and bandwidth, rails, offset, bias currents, input capacitance, output resistance, and explicit input/output noise spectra.
- `VoltageControlledSwitch` selects smooth or event-oriented resistance transitions and can model feedthrough and charge injection.

These models are deliberately focused. They are useful for circuit reasoning and numerical experimentation, not drop-in foundry models. The MOSFET models cover Level 1 and a bounded charge-based long-channel formulation rather than BSIM, and some declared behavioral op-amp limits are reserved rather than enforced. Read [Physical model scope](@ref) and [Current limitations](@ref) before interpreting edge-of-validity results.

```@example models
using Amber
logic_device = Level1MOSFET(
    threshold_voltage=0.7V,
    transconductance=2mA / V^2,
    channel_length_modulation=0.03 / V,
    gate_source_capacitance=8pF,
    gate_drain_capacitance=2pF,
)
logic_device
```

`nmos(drain, gate, source, bulk; model=...)` and
`pmos(drain, gate, source, bulk; model=...)` always use a positive threshold
voltage magnitude. Connect the NMOS bulk to its lowest rail and the PMOS bulk
to its highest rail for the usual CMOS configuration.

## Extended device catalogue

The following constructors work with `add!` and `@circuit`. All values use SI
units (Amber unit constants are accepted). These are compact engineering
models; their defaults are illustrative, not fitted manufacturer parts.

| Constructors | Terminals | Model and main parameters |
|:--|:--|:--|
| `zener` | anode, cathode | Junction avalanche; positive `breakdown_voltage`, `breakdown_current`, other `JunctionDiode` keywords |
| `schottky`, `led` | anode, cathode | Junction diode presets; override `JunctionDiode` keywords |
| `photodiode` | anode, cathode | `model` junction plus constant reverse `photocurrent` |
| `solar_cell` | positive, negative | Photodiode equivalent plus `shunt_resistance`; junction model can supply series resistance |
| `njfet`, `pjfet` | drain, gate, source | Square-law channel, `idss`, negative normalized `pinch_off`, `channel_length_modulation` |
| `thermistor` | a, b | Fixed-temperature NTC beta law, `rnom`, `beta`, `temperature`, `nominal_temperature` |
| `varistor` | a, b | Symmetric power law, `vref`, `iref`, `exponent > 1` |
| `voltage_controlled_resistor` | a, b, control+, control− | Smooth resistance between `rmin` and `rmax`, `threshold`, `transition` |
| `potentiometer` | top, wiper, bottom | Two resistors, total `resistance`, `0 < position < 1` measured from bottom |
| `analog_multiplier` | x+, x−, y+, y−, out+, out− | Ideal voltage output, `gain * Vx * Vy + offset` |
| `voltage_limiter`, `comparator` | control+, control−, out+, out− | Smooth tanh transfer, `low`, `high`, `gain`, input `offset` |
| `ideal_transformer` | primary+, primary−, secondary+, secondary− | Lossless, positive `ratio = Vprimary/Vsecondary` |
| `bridge_rectifier` | AC1, AC2, DC+, DC− | Four diodes sharing a `model` |
| `crystal` | a, b | Series `motional_resistance`, `motional_inductance`, `motional_capacitance`, in parallel with `shunt_capacitance` |
| `transmission_line` | input, output, reference | Cascaded pi sections; **total** `resistance`, `inductance`, `conductance`, `capacitance`, and integer `sections` |

JFET `idss` is the saturated current magnitude at zero gate/source voltage.
Both polarities use a negative normalized pinch-off voltage. The channel
swaps source and drain for reverse operation, and omits gate-junction current,
capacitance, subthreshold conduction and device noise. Avoid forward gate bias
when interpreting it as a physical JFET.

The thermistor evaluates `rnom * exp(beta * (1/T - 1/Tnom))` at construction.
Its explicit temperature is independent of analysis temperature and it has no
self-heating state. The LED models only electrical behavior. Photocurrent is
constant and contributes no additional shot noise; junction noise still uses
the underlying diode. The varistor omits leakage, capacitance and thermal
effects. Its power law can overflow at extreme voltages.

The comparator has neither hysteresis nor propagation delay. Its output levels
are fixed parameters, not supply terminals. For limiter and comparator,
`mid + span*tanh(gain*(Vin-offset)/span)` uses the midpoint and half-width of
the output range. Signal blocks and the controlled resistor have no intrinsic
noise. Add output impedance externally to the ideal voltage-output blocks.

The ideal transformer includes no magnetizing inductance, leakage or core
loss. Each winding needs a circuit reference. The crystal is a linear motional
equivalent. The line is a finite lumped approximation, not an exact delay line;
increase `sections` and verify convergence for the bandwidth of interest.

### Persistence, parameters and observations

Composite constructors expand into existing primitives when added. They
inherit those primitives' DC, transient, AC and noise support. All catalogue
circuits serialize, including the named callable laws used by nonlinear
behavioral devices. The serialized representation contains the expanded
primitives, not a separate composite model.

The returned handle identifies the main primitive: junction for photodiodes
and solar cells, top resistor for a potentiometer, primary voltage source for
a transformer, AC1-to-DC+ diode for a bridge, shunt capacitor for a crystal,
and first inductor for a line. `current(handle)` and `power(handle)` therefore
refer to that primitive, **not the complete composite**. For total port current,
insert a zero-volt sensing source; sum branch powers for total dissipation.
Generated parts have suffixes such as `T.secondary`, `cell.photocurrent`,
`pot.bottom`, and `xtal.motional_l`, visible through `devices(design)`.

Catalogue parameters must be concrete numerical values at construction; use a
Julia circuit factory to vary them. Literal-valued catalogue devices can be
used inside `@subcircuit`; symbolic template parameter expressions are not
supported by catalogue validation and nonlinear laws. Compiled parameter
updates target the expanded primitive parameters rather than the original
constructor keywords.

```@example catalogue
using Amber
@circuit TransformerDivider begin
    gnd = ground(); primary = node(); secondary = node(); tap = node()
    supply = voltage_source(primary, gnd; dc=10V)
    T = ideal_transformer(primary, gnd, secondary, gnd; ratio=2)
    pot = potentiometer(secondary, tap, gnd; resistance=100Ω, position=0.25)
end
result = operating_point(TransformerDivider())
voltage(result, :tap) # 1.25 V
```
