# Noise analysis

`noise` computes small-signal spectral densities around an operating point. It propagates independent device-noise sources to a chosen output with adjoint solves.

```@example noise_manual
using Amber
@circuit ResistorNoise() begin
    gnd=ground(); n=node()
    R1=resistor(n,gnd;value=10kΩ)
    observe(voltage(n))
end
r = noise(ResistorNoise(), 10Hz=>100kHz; output=voltage(:n), points=3)
output_noise_density(r)
```

Output density has the units of the selected output per square-root hertz. When an input source is supplied, `input_referred_noise_density` divides by small-signal gain and warns near transfer nulls.

The current source set covers resistor thermal noise and diode/BJT shot-noise contributions. Flicker noise and source correlation are not yet modeled. Noise analysis is linear: it does not describe periodically time-varying noise or large-signal modulation.
