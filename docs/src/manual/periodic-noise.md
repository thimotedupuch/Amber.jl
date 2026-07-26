# Periodic and oscillator noise

`periodic_noise` consumes a converged `PSSResult`, Fourier-expands the
time-varying DAE and device covariance, and solves a lifted harmonic system:

```julia
pss = periodic_steady_state(circuit; period=1μs)
result = periodic_noise(pss, 10Hz => 100kHz;
    output=voltage(:output),
    output_harmonic=0,
    sidebands=-7:7,
)
```

Noise from every included source sideband is folded into the selected output
harmonic. Energy at the sideband boundary is reported as a truncation
diagnostic. Increase the sideband range until the result stabilizes.

For autonomous oscillators, construct PSS with `autonomous=true` and
`method=:bdf1`. The one-step method gives the variational and adjoint maps one
unambiguous discrete contract. Amber solves state and period with a phase
condition and checks for one isolated neutral Floquet multiplier. `phase_noise`
projects physical noise through the periodic adjoint phase-sensitivity waveform
and reports single-sideband phase noise in linear ratio and dBc/Hz:

```julia
pss = periodic_steady_state(oscillator;
    period=initial_period,
    autonomous=true,
    method=:bdf1,
)
pn = phase_noise(pss, 100Hz => 1MHz;
    output=voltage(:output),
    sidebands=-9:9,
)
```

An absent or ambiguous neutral mode is an analysis error. PNoise accuracy
depends on the PSS orbit, its time grid, and sideband truncation.
