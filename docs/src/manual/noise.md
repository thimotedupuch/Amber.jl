# Stationary noise analysis

`noise` linearizes a circuit at a DC operating point and propagates physical
device-noise covariance through the linearized DAE. All reported spectra are
one-sided power spectral densities (PSDs). `noise_density` returns their square
root, often called amplitude spectral density.

```@example noise_manual
using Amber
@circuit ResistorNoise() begin
    gnd = ground()
    n = node()
    R1 = resistor(n, gnd; value=10kΩ)
    observe(voltage(n))
end

r = noise(ResistorNoise(), 10Hz => 100kHz; output=voltage(:n), points=3)
noise_psd(r)
noise_density(r)
```

PSD has units of the squared selected output per hertz. Density has units of
the output per square-root hertz. RMS noise is obtained by integrating PSD:

```@example noise_manual
integrated_noise(r, 10Hz => 100kHz)
```

Band edges are interpolated exactly by default and must lie inside the
evaluated frequency range. Use `quantity=:variance` for integrated power and
`contributions=true` to return the per-source integrals.

When `input` names an independent source, Amber also divides output PSD by the
squared small-signal conversion gain:

```julia
r = noise(circuit, 10Hz => 1MHz;
    output=voltage(:output), input=:Input)
input_referred_noise_psd(r)
input_referred_noise_density(r)
```

At a conversion null, input-referred PSD is `Inf` and the result contains a
warning. `noise_contributions` filters source attribution by component or
mechanism.

## Implemented mechanisms

Amber includes resistor/conductance and switch-channel thermal noise, diode
carrier and avalanche shot noise, BJT transport shot noise, MOS channel
thermal and optional induced-gate noise, explicit power-law noise, and
behavioral op-amp voltage/current/output-resistance noise. Correlated sources
are propagated as complex Hermitian covariance groups rather than being added
as independent powers.

Power-law noise is never evaluated at DC. Its coefficient is interpreted in SI
units according to the documented model formula, and its reference frequency
must be positive.

For diode, BJT, MOSFET, and thin-film current noise, Amber uses

```math
S_i(f)=K\,|I|^{a_I}\left(\frac{f_\mathrm{ref}}{f}\right)^{a_f}.
```

Thus `flicker_coefficient` or `excess_noise_coefficient` has whatever SI scale
is required to make ``S_i`` an ``\mathrm{A^2/Hz}`` quantity; Amber does not
reinterpret it as a foundry-model `KF`. The current and frequency exponents and
reference frequency are explicit model parameters.

Behavioral op-amp density parameters are amplitudes in volts or amperes per
square-root hertz. Their flicker-corner contribution multiplies white PSD by
``(f_c/f)^a``.
