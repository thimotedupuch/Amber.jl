# Stochastic transient noise

`transient_noise` produces a seeded stochastic realization on a mandatory
fixed internal grid:

```julia
result = transient_noise(circuit, 0s => 10ms;
    timestep=1μs,
    saveat=10μs,
    seed=42,
)
```

The method is stochastic backward Euler. For a one-sided white PSD ``S``, each
grid sample has variance ``S/(2\Delta t)``, so the represented bandwidth ends
at the Nyquist frequency ``1/(2\Delta t)``. `saveat` must be an integer
multiple of `timestep`, the interval must contain an integer number of steps,
and exact events must lie on the same grid.

Bias-dependent source intensity uses the state at the beginning of each step,
which defines Amber's multiplicative-noise convention as Itô.

Power-law sources use a finite record with explicit low-frequency cutoff. The
default cutoff is the inverse record duration. Noise below that cutoff is not
represented and is reported in result warnings.

The seed, timestep, cutoffs, source count, and convergence information are
stored in the result. Identical inputs reproduce the same source realization
on the same Amber and Julia versions.
