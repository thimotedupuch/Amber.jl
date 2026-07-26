# AC linearization and noise propagation

At a DC solution ``x_0``, linearization yields

```math
(G+j\omega C)\hat{x}=\hat{b},
```

where ``G=\partial F/\partial x`` and ``C=\partial F/\partial\dot{x}`` at the bias point. One complex solve per frequency gives the small-signal response.

For noise, each physical source has a power spectral density. Rather than solving once per source and output, an adjoint solve maps source injections to the selected output efficiently. Independent powers add, while correlated mechanisms are propagated through complex Hermitian cross-spectral matrices.

This framework explains the limitations: the bias must exist, perturbations must be small, and every correlation needs explicit device-model support. Noise spectral density is not RMS noise until its PSD is integrated over bandwidth, including the transfer function and units.
