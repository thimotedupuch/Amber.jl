module Amber

using LinearAlgebra
using AbstractFFTs
using FFTW
using Random
using SparseArrays
using SHA
using Statistics
using TOML

export Circuit, Node, Ground, Component, CompiledTopology, CompiledCircuit, SimulationResult
export ConvergenceError
export CircuitValidationError, AnalysisValidationError, LinearSolveError
export CircuitSerializationError
export circuit, node!, ground!, add!, observe!, observe, compile, check, describe
export explain, explain_failure
export circuit_snapshot, serialize_circuit, deserialize_circuit, save_circuit, load_circuit
export node, ground, resistor, capacitor, inductor, conductance
export voltage_source, current_source, diode, npn, nmos, pmos, opamp, analog_switch
export transconductance, voltage_controlled_voltage_source
export current_controlled_current_source, current_controlled_voltage_source
export voltage, current, power, charge, state, initial_voltage
export differential_capacitance
export operating_point, transient, small_signal, simulate, run, sweep
export noise, NoiseResult, output_noise_density, input_referred_noise_density
export OperatingPoint, Transient, SmallSignal, frequencies, trace, transfer
export Port, NetworkResult, port_response, network_parameters, impedance, admittance, renormalize
export MatchedGroup, matched_group, Differential
export Gaussian, LogNormal, UniformVariation, ProcessVariation, CorrelatedVariation, MonteCarloFailure, MonteCarloResult
export monte_carlo, replay_sample, sample_values, sample_parameters, successful, failure_rate, yield_rate, confidence_interval
export yield_confidence_interval
export serialize_monte_carlo, deserialize_monte_carlo, save_monte_carlo, load_monte_carlo
export magnitude, phase, region, ForwardActive, Saturation, Cutoff, Triode
export db20, db10, group_delay, phase_delay, crossings, cutoff_frequencies, FrequencyBand, passbands, bandwidth
export Resonance, resonances, quality_factor, peaking, notch_depth, integrated_noise
export SpectrumResult, HarmonicComponent, HarmonicResult, spectrum, harmonic_analysis
export thd, thdn, snr, sinad, sfdr, enob, crest_factor, band_power
export LinearizedModel, LinearFrequencyResponse, TimeResponse, linearize, frequency_response, dcgain
export poles, transmission_zeros, natural_frequencies, damping_ratios, isstable
export gain_crossovers, phase_crossovers, StabilityMargins, stability_margins, gain_margin, phase_margin
export sensitivity, complementary_sensitivity, step_response, impulse_response
export rise_time, settling_time, peak_time, steady_state_error, root_locus
export AbstractLoopProbe, VoltageLoopProbe, CurrentLoopProbe, LoopGainResult
export loop_gain, loop_sensitivity, closed_loop_response
export PeriodicSteadyState, PSSResult, periodic_steady_state, floquet_multipliers
export provenance, report, validity_report, available_observables
export result_table
export compare, peak_to_peak, sampling_metrics, propagation_delay, overshoot
export Step, Sine, Pulse, ThinFilm, SMD0603, C0G, DebyeBranches
export JunctionDiode, GummelPoonBJT, Level1MOSFET, BehavioralOpAmp, VoltageControlledSwitch
export SmoothSwitch, EventSwitch, IdealResistor, IdealCapacitor
export @circuit
export Ω, fΩ, pΩ, nΩ, μΩ, mΩ, kΩ, MΩ, GΩ, TΩ
export V, fV, pV, nV, μV, mV, kV, MV, GV, TV
export A, fA, pA, nA, μA, mA, kA, MA, GA, TA
export F, fF, pF, nF, μF, mF, kF, MF, GF, TF
export H, fH, pH, nH, μH, mH, kH, MH, GH, TH
export C, fC, pC, nC, μC, mC, kC, MC, GC, TC
export s, fs, ps, ns, μs, ms, ks, Ms, Gs, Ts
export Hz, fHz, pHz, nHz, μHz, mHz, kHz, MHz, GHz, THz
export S, fS, pS, nS, μS, mS, kS, MS, GS, TS
export K, fK, pK, nK, μK, mK, kK, MK, GK, TK
export m, fm, pm, nm, μm, mm, km, Mm, Gm, Tm
export dB, percent
export °

include("Core/Units.jl")
include("Core/Ports.jl")
include("Devices/Models.jl")
include("Core/CircuitIR.jl")
include("Core/Serialization.jl")
include("Devices/Ideal.jl")
include("Devices/Passive.jl")
include("Devices/Semiconductor.jl")
include("Devices/Behavioral.jl")
include("Diagnostics/Diagnostics.jl")
include("Core/EquationGraph.jl")
include("Core/Compilation.jl")
include("Analysis/Analyses.jl")
include("Results/Results.jl")
include("Results/Tabular.jl")
include("Solvers/Nonlinear.jl")
include("Solvers/OperatingPoint.jl")
include("Solvers/Transient.jl")
include("Solvers/PeriodicSteadyState.jl")
include("Solvers/SmallSignal.jl")
include("Solvers/Network.jl")
include("Analysis/Control.jl")
include("Analysis/Feedback.jl")
include("Solvers/Noise.jl")
include("Analysis/Sweeps.jl")
include("Analysis/MonteCarlo.jl")
include("Analysis/Metrics.jl")
include("Analysis/FrequencyMetrics.jl")
include("Analysis/Spectrum.jl")
include("Documentation.jl")

end
