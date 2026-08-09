# Monte Carlo analysis

Amber makes statistical circuit experiments reproducible and inspectable. A run combines parameter variations, an analysis callback, and named metrics into a `MonteCarloResult` retaining samples, successes, failures, seeds, and provenance.

Variations include `Gaussian`, `LogNormal`, and bounded `UniformVariation`, plus shared `ProcessVariation`, covariance-driven `CorrelatedVariation`, and `MatchedGroup`. Device parameter paths connect them to named circuit elements.

The essential workflow is:

1. Verify the nominal circuit and metric.
2. Define physical distributions and correlations.
3. Use an explicit seed.
4. Treat failed samples as data.
5. Report confidence intervals, not only point estimates.

`successful`, `failure_rate`, `yield_rate`, `confidence_interval`, and `yield_confidence_interval` summarize a run. `sample_values` and `sample_parameters` expose each trial. `replay_sample` reconstructs a trial for diagnosis. Parallel execution does not make the random draw sequence depend on scheduling.

Persistence methods preserve the statistical artifact. Loading a result does not require rerunning the circuit; replay requires a compatible circuit and callback. See [Precision bridge yield](@ref) for an end-to-end experiment.
