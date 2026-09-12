# Devices and models

## Constructors

```@docs
resistor
capacitor
inductor
conductance
voltage_source
current_source
behavioral_current_source
behavioral_voltage_source
diode
npn
nmos
pmos
opamp
analog_switch
transconductance
voltage_controlled_voltage_source
current_controlled_current_source
current_controlled_voltage_source
zener
schottky
led
photodiode
solar_cell
njfet
pjfet
thermistor
varistor
voltage_controlled_resistor
potentiometer
analog_multiplier
voltage_limiter
comparator
ideal_transformer
bridge_rectifier
crystal
transmission_line
```

`behavioral_current_source(controls, output_p, output_n; current, gradient)`
accepts up to four `(positive, negative)` control-node pairs. Its callbacks
receive the four differential voltages and simulation time. `gradient` returns
the four partial derivatives of `current`, keeping the sparse Newton Jacobian
consistent with the residual. The multiphysics examples under
`examples/17_beyond_electronics` demonstrate state-equation use.

`behavioral_voltage_source(controls, output_p, output_n; voltage, gradient)`
uses the same control convention and imposes an ideal nonlinear voltage
constraint. It introduces a branch-current unknown; add an external resistor
when finite output impedance is needed.

## Models and waveforms

```@docs
Step
Sine
Pulse
ThinFilm
SMD0603
C0G
DebyeBranches
JunctionDiode
GummelPoonBJT
Level1MOSFET
BehavioralOpAmp
VoltageControlledSwitch
SmoothSwitch
EventSwitch
IdealResistor
IdealCapacitor
model_parameters
with_model_parameter
differential_capacitance
```
