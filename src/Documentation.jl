# Public documentation lives together so `?Amber.name` and Documenter expose the
# same contract without coupling narrative text to implementation files.

@doc """Abstract supertype of Amber circuit components.""" Component
@doc """Mutable circuit intermediate representation containing named nodes, components, and observables.""" Circuit
@doc """A non-reference electrical node belonging to a `Circuit`.""" Node
@doc """The zero-volt reference node of a `Circuit`.""" Ground
@doc """Reusable structural indexing and sparse-pattern information produced by `compile`.""" CompiledTopology
@doc """A frozen circuit plus its compiled topology, suitable for repeated analyses.""" CompiledCircuit
@doc """Common result container for operating-point, transient, and small-signal analyses.""" SimulationResult

@doc """Create an empty named circuit.""" circuit
@doc """Add and return a uniquely named electrical node.""" node!
@doc """Create or return the circuit reference node.""" ground!
@doc """Add a component to a circuit and return it.""" add!
@doc """Register one or more observables on a circuit.""" observe!
@doc """Register observables in the `@circuit` construction DSL.""" observe
@doc """Validate and compile a circuit into indexed generalized-MNA form.""" compile
@doc """Construct an unnamed node inside `@circuit`.""" node
@doc """Return the reference node inside `@circuit`.""" ground
@doc """Define a parameterized circuit constructor using Amber's compact circuit DSL.""" :(@circuit)

@doc """Construct an ideal or modeled resistor between two nodes.""" resistor
@doc """Construct a capacitor, optionally with ESR, leakage, initial voltage, and dielectric absorption.""" capacitor
@doc """Construct an inductor, optionally with winding resistance and initial current.""" inductor
@doc """Construct a two-terminal conductance.""" conductance
@doc """Construct an independent voltage source with DC, AC, and/or transient specifications.""" voltage_source
@doc """Construct an independent current source with DC, AC, and/or transient specifications.""" current_source
@doc """Construct a source in the circuit DSL, dispatching from its specification.""" source
@doc """Construct a junction diode.""" diode
@doc """Construct an NPN bipolar transistor with collector, base, and emitter terminals.""" npn
@doc """Construct a four-terminal NMOS transistor with drain, gate, source, and bulk terminals.""" nmos
@doc """Construct a four-terminal PMOS transistor with drain, gate, source, and bulk terminals.""" pmos
@doc """Construct a five-terminal behavioral op amp.""" opamp
@doc """Construct a voltage-controlled analog switch.""" analog_switch
@doc """Construct a voltage-controlled current source with gain in siemens.""" transconductance
@doc """Alias for `transconductance`.""" voltage_controlled_current_source
@doc """Construct a voltage-controlled voltage source.""" voltage_controlled_voltage_source
@doc """Alias for `voltage_controlled_voltage_source`.""" voltage_amplifier
@doc """Construct a current-controlled current source.""" current_controlled_current_source
@doc """Alias for `current_controlled_current_source`.""" current_amplifier
@doc """Construct a current-controlled voltage source with gain in ohms.""" current_controlled_voltage_source
@doc """Alias for `current_controlled_voltage_source`.""" transresistance

@doc """A transient waveform that changes from `initial` to `final` at a specified time.""" Step
@doc """A sinusoidal transient waveform with amplitude, frequency, phase, offset, and delay.""" Sine
@doc """A periodic pulse waveform with explicit rise, fall, frequency, and duty cycle.""" Pulse
@doc """Thin-film resistor technology metadata.""" ThinFilm
@doc """0603 surface-mount resistor technology metadata.""" SMD0603
@doc """C0G/NP0 capacitor technology metadata.""" C0G
@doc """A sum of Debye relaxation branches used to model dielectric absorption.""" DebyeBranches
@doc """Junction-diode compact-model parameters.""" JunctionDiode
@doc """NPN compact-model parameters for transport, Early effect, charge, and base resistance.""" GummelPoonBJT
@doc """Level-1 MOSFET parameters for threshold/body effect, channel current, gate capacitance, and thermal noise.""" Level1MOSFET
@doc """Behavioral op-amp parameters for gain, bandwidth, rails, offsets, and impedances.""" BehavioralOpAmp
@doc """Voltage-controlled switch parameters including resistance, threshold, and parasitics.""" VoltageControlledSwitch
@doc """Smooth continuously differentiable switch transition mode.""" SmoothSwitch
@doc """Event-oriented switch transition mode.""" EventSwitch
@doc """Ideal resistor model marker.""" IdealResistor
@doc """Ideal capacitor model marker.""" IdealCapacitor
@doc """Return a model's local differential capacitance at the supplied bias.""" differential_capacitance

@doc """Construct a named voltage observable between two nodes.""" voltage
@doc """Construct or evaluate a component-current observable.""" current
@doc """Construct or evaluate a component-power observable using the passive sign convention.""" power
@doc """Construct or evaluate a stored-charge observable.""" charge
@doc """Construct an observable for a named internal device state.""" state
@doc """Return the configured initial voltage of an energy-storage element.""" initial_voltage

@doc """Operating-point analysis descriptor.""" OperatingPoint
@doc """Transient-analysis descriptor.""" Transient
@doc """Small-signal frequency-analysis descriptor.""" SmallSignal
@doc """Solve the nonlinear DC operating point of a circuit.""" operating_point
@doc """Integrate a circuit over a time span using implicit BDF methods.""" transient
@doc """Linearize at the operating point and solve at the requested frequencies.""" small_signal
@doc """Execute an Amber analysis descriptor on a circuit.""" simulate
@doc """Alias for `simulate`.""" run
@doc """Evaluate an analysis across a deterministic parameter grid.""" sweep
@doc """Compute small-signal output and optionally input-referred noise spectral density.""" noise
@doc """Frequency-indexed noise-analysis result including density, transfer, warnings, and provenance.""" NoiseResult

@doc """Return the frequency vector of a frequency-domain result.""" frequencies
@doc """Return a named observable trace from a result.""" trace
@doc """Return a complex small-signal transfer trace.""" transfer
@doc """Return the magnitude of a complex result trace.""" magnitude
@doc """Return the phase of a complex result trace in radians.""" phase
@doc """Classify the operating region of a supported nonlinear device.""" region
@doc """BJT forward-active operating-region marker.""" ForwardActive
@doc """BJT saturation operating-region marker.""" Saturation
@doc """BJT cutoff operating-region marker.""" Cutoff
@doc """MOSFET linear/triode operating-region marker.""" Triode
@doc """Return result-generation metadata and solver settings.""" provenance
@doc """Create a readable summary of a circuit or result.""" report
@doc """Return physical-validity findings recorded for a result.""" validity_report
@doc """List observable names available in a result.""" available_observables
@doc """Convert a result to a Tables.jl-compatible table.""" result_table
@doc """Compare compatible simulation results with structured numeric differences.""" compare
@doc """Return the maximum minus minimum of a trace or selected window.""" peak_to_peak
@doc """Compute steady-period metrics such as mean and ripple.""" periodic_metrics
@doc """Compute acquisition and hold errors for sampled waveforms.""" sampling_metrics
@doc """Measure threshold-crossing delay between two waveforms.""" propagation_delay
@doc """Measure excursion beyond a specified final or reference value.""" overshoot
@doc """Return output amplitude spectral density from a `NoiseResult`.""" output_noise_density
@doc """Return input-referred amplitude spectral density from a `NoiseResult`.""" input_referred_noise_density
@doc """A differential small-signal excitation or observation specification.""" Differential

@doc """Independent normally distributed parameter variation.""" Gaussian
@doc """Independent positive lognormally distributed parameter variation.""" LogNormal
@doc """Independent bounded uniform parameter variation.""" UniformVariation
@doc """A shared random process contribution applied to multiple parameter paths.""" ProcessVariation
@doc """A multivariate normal parameter variation defined by means and covariance.""" CorrelatedVariation
@doc """Definition of components sharing process variation with local mismatch.""" MatchedGroup
@doc """Construct a `MatchedGroup` for statistically matched components.""" matched_group
@doc """Captured failure information for one Monte Carlo sample.""" MonteCarloFailure
@doc """Complete reproducible Monte Carlo artifact containing draws, metrics, failures, seed, and provenance.""" MonteCarloResult
@doc """Run a seeded circuit Monte Carlo experiment, optionally in parallel.""" monte_carlo
@doc """Reconstruct and rerun one sample from a `MonteCarloResult`.""" replay_sample
@doc """Return the sampled random values for one or all trials.""" sample_values
@doc """Return resolved component parameters for one or all trials.""" sample_parameters
@doc """Return the successful samples of a Monte Carlo result.""" successful
@doc """Return the fraction of Monte Carlo samples that failed analysis.""" failure_rate
@doc """Estimate the fraction of successful samples satisfying a predicate.""" yield_rate
@doc """Compute a confidence interval for a numeric Monte Carlo metric.""" confidence_interval
@doc """Compute a binomial confidence interval for estimated yield.""" yield_confidence_interval

@doc """Validate circuit structure and return diagnostics; throw on invalid input where requested.""" check
@doc """Return a human-readable structural description of a circuit.""" describe
@doc """Explain a circuit, analysis, or result in human-readable form.""" explain
@doc """Explain a typed Amber failure and likely corrective actions.""" explain_failure
@doc """Invalid circuit structure or parameter error.""" CircuitValidationError
@doc """Invalid analysis configuration error.""" AnalysisValidationError
@doc """Nonlinear solver convergence failure with diagnostic context.""" ConvergenceError
@doc """Sparse or dense linear-system solution failure.""" LinearSolveError
@doc """Circuit or result serialization format error.""" CircuitSerializationError

@doc """Return the deterministic, serializable snapshot representation of a circuit.""" circuit_snapshot
@doc """Serialize a supported circuit to versioned TOML text.""" serialize_circuit
@doc """Deserialize versioned TOML text into a circuit.""" deserialize_circuit
@doc """Save a supported circuit to a TOML file.""" save_circuit
@doc """Load a circuit from an Amber TOML file.""" load_circuit
@doc """Serialize a `MonteCarloResult` to versioned TOML text.""" serialize_monte_carlo
@doc """Deserialize a `MonteCarloResult` from versioned TOML text.""" deserialize_monte_carlo
@doc """Save a `MonteCarloResult` to a TOML file.""" save_monte_carlo
@doc """Load a `MonteCarloResult` from an Amber TOML file.""" load_monte_carlo

for (name, description) in (
    (:Ω,"ohm"), (:kΩ,"kilohm"), (:MΩ,"megohm"), (:GΩ,"gigohm"), (:TΩ,"teraohm"), (:mΩ,"milliohm"),
    (:V,"volt"), (:mV,"millivolt"), (:μV,"microvolt"), (:nV,"nanovolt"),
    (:A,"ampere"), (:mA,"milliampere"), (:μA,"microampere"), (:nA,"nanoampere"), (:pA,"picoampere"), (:fA,"femtoampere"),
    (:F,"farad"), (:mF,"millifarad"), (:μF,"microfarad"), (:nF,"nanofarad"), (:pF,"picofarad"), (:fF,"femtofarad"),
    (:H,"henry"), (:mH,"millihenry"), (:μH,"microhenry"), (:nH,"nanohenry"), (:pH,"picohenry"),
    (:C,"coulomb"), (:mC,"millicoulomb"), (:μC,"microcoulomb"), (:nC,"nanocoulomb"), (:pC,"picocoulomb"), (:fC,"femtocoulomb"),
    (:s,"second"), (:ms,"millisecond"), (:μs,"microsecond"), (:ns,"nanosecond"), (:ps,"picosecond"),
    (:Hz,"hertz"), (:kHz,"kilohertz"), (:MHz,"megahertz"), (:GHz,"gigahertz"), (:K,"kelvin"),
    (:m,"metre scale factor"), (:μS,"microsiemens"), (:dB,"decibel amplitude conversion"), (:percent,"percent scale factor"), (:°,"degree-to-radian conversion"),
)
    @eval @doc $("Numeric SI scale factor for one " * description * ".") $name
end
