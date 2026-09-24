include("circuit.jl")

inverter = CMOSInverter()
@assert isempty(check(inverter))
vtc = sweep(
    inverter, "Input.dc" => range(0V, 5V; length = 401);
    analysis = OperatingPoint(), metric = r -> only(voltage(r, :output))
)
@assert failure_rate(vtc) == 0
dc_transfer = Float64.(vtc.metrics)
margins = invertermetrics(vtc; output = :output)
@assert isempty(margins.warnings)

switching = CMOSInverter(
    waveform = Pulse(
        low = 0V, high = 5V, frequency = 10MHz,
        duty_cycle = 0.5, rise = 1ns, fall = 1ns
    )
)
@assert isempty(check(switching))
window = 100ns => 200ns  # one settled cycle; energy includes leakage
function measure_switching(step)
    result = transient(
        switching, 0s => 210ns; event_mode = :exact, max_step = step,
        method = :bdf2, failure_policy = :throw
    )
    metrics = switchingmetrics(result; input = :input, output = :output, supply = :VDD, vdd = 5V, window)
    @assert all(isfinite, (metrics.tphl, metrics.tplh, metrics.energy))
    return result, metrics
end
coarse, coarse_metrics = measure_switching(50ps)
waveforms, metrics = measure_switching(25ps)
relative_change = NamedTuple{(:tphl, :tplh, :energy)}(
    Tuple(
        abs(getproperty(metrics, k) - getproperty(coarse_metrics, k)) / abs(getproperty(metrics, k))
            for k in (:tphl, :tplh, :energy)
    )
)
@assert all(<(0.01), values(relative_change)) "Refine further: delay/energy changed by more than 1%"
# A single selected edge can also be measured explicitly.
delay = propagation_delay(
    waveforms; input = :input, output = :output, threshold = 2.5V,
    input_edge = :rising, output_edge = :falling, window
)
@assert isapprox(delay, metrics.tphl)
println(
    (
        noise_margins = margins.measurements, delay_s = metrics.tphl,
        rise_delay_s = metrics.tplh, energy_J = metrics.energy, relative_change,
    )
)
println(report(waveforms; window))
