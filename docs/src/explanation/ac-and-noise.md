# AC linearization and noise propagation

At a DC solution ``x_0``, linearization yields

```math
(G+j\omega C)\hat{x}=\hat{b},
```

where ``G=\partial F/\partial x`` and ``C=\partial F/\partial\dot{x}`` at the bias point. One complex solve per frequency gives the small-signal response.

For noise, each physical source has a power spectral density. Rather than solving once per source and output, an adjoint solve maps all independent sources to the selected output efficiently. Their powers add because the present model assumes independence.

This framework explains the limitations: the bias must exist, perturbations must be small, and correlations need explicit model support. Noise spectral density is not RMS noise until integrated over bandwidth, including the transfer function and units.

