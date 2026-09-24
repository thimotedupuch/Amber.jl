# Run with Amber, AmberMakie, CairoMakie and Random available.
using Amber, AmberMakie, CairoMakie, Random
CairoMakie.activate!()
set_theme!(theme_amber_light())
output_dir = get(ENV, "AMBERMAKIE_DEMO_OUTPUT", joinpath(@__DIR__, "generated"))
mkpath(output_dir)

@circuit StudyInverter(; vdd = 1.8, load = 10.0e-15, switching = false) begin
    gnd = ground(); supply = node(); input = node(); output = node()
    model = ChargeBasedMOSFET(channel_length_modulation = 0.02)
    VDD = voltage_source(supply, gnd; dc = vdd)
    VG = voltage_source(
        input, gnd; dc = 0.0, waveform = switching ?
            Pulse(low = 0.0, high = vdd, frequency = 1.0e7, rise = 2.0e-9, fall = 2.0e-9) : nothing
    )
    MN = nmos(output, input, gnd, gnd; model, width = 4.0e-6)
    MP = pmos(output, input, supply, supply; model, width = 4.0e-6)
    CL = capacitor(output, gnd; value = load)
end

transfer_sweep = sweep(StudyInverter(), "VG.dc" => range(0, 1.8; length = 401))
transfer = inverterview(transfer_sweep; output = :output)
@assert isempty(transfer.warnings)
fig = Figure(size = (800, 800)); inverterplot(fig[1, 1], transfer)
save(joinpath(output_dir, "34_inverter_noise_margins.png"), fig)

# Solver convergence alone does not establish delay/energy accuracy. Retain
# each refinement and require all three measurements to change by <1%.
function refined_switching(load, vdd; rtol = 0.01, max_refinements = 8)
    circuit = StudyInverter(; load, vdd, switching = true)
    @assert isempty(check(circuit))
    history = NamedTuple[]
    for refinement in 0:max_refinements
        step = 0.5e-9 / 2^refinement
        result = transient(
            circuit, 0.0 => 210.0e-9; max_step = step, method = :bdf2,
            event_mode = :exact, failure_policy = :throw
        )
        measurements = switchingmetrics(
            result; input = :input, output = :output, supply = :VDD, vdd,
            window = 100.0e-9 => 200.0e-9
        )
        all(isfinite, (measurements.tphl, measurements.tplh, measurements.energy)) ||
            error("Missing or ambiguous switching measurements")
        push!(
            history, (
                max_step = step, tphl = measurements.tphl, tplh = measurements.tplh,
                energy = measurements.energy,
            )
        )
        refinement == 0 && continue
        previous = history[end - 1]
        change = NamedTuple{(:tphl, :tplh, :energy)}(
            Tuple(
                abs(getproperty(measurements, k) - getproperty(previous, k)) / abs(getproperty(measurements, k))
                    for k in (:tphl, :tplh, :energy)
            )
        )
        if all(<(rtol), values(change))
            println((load_F = load, supply_V = vdd, max_step_s = step, relative_change = change))
            return merge(measurements, (result = result, refinement = history, relative_change = change))
        end
    end
    error("Switching refinement did not reach $(rtol) relative change: $(history)")
end
switching = switchingview(refined_switching; loads = [5.0e-15, 20.0e-15, 80.0e-15], supplies = [1.5, 1.8, 2.1])
@assert isempty(switching.failures)
@assert all(p -> isfinite(p.tphl)&&isfinite(p.tplh)&&p.energy > 0, switching.points)
fig = Figure(size = (1400, 500)); switchingplot(fig[1, 1], switching)
save(joinpath(output_dir, "35_cmos_delay_energy.png"), fig)

# Input-referred mismatch of a pair with ideal source/drain clamps:
# both sources/bulks at 0 V, drains at 1 V, gates at 1 V ± offset/2.
# Find the differential gate voltage that balances drain currents.
# Illustrative independent threshold and mobility variation; NOT a process kit.
@circuit OffsetPair(; left, right, offset) begin
    gnd = ground(); drain = node(); ga = node(); gb = node()
    VD = voltage_source(drain, gnd; dc = 1.0)
    VA = voltage_source(ga, gnd; dc = 1.0 + offset / 2)
    VB = voltage_source(gb, gnd; dc = 1.0 - offset / 2)
    MA = nmos(drain, ga, gnd, gnd; model = left)
    MB = nmos(drain, gb, gnd, gnd; model = right)
end
function offset_sample(width, len, temperature, z)
    area_um2 = width * len / 1.0e-12
    left = ChargeBasedMOSFET(;
        width, length = len, threshold_voltage = 0.7 + 0.003z[1] / sqrt(area_um2),
        mobility = 0.04 * (1 + 0.01z[2] / sqrt(area_um2))
    )
    right = ChargeBasedMOSFET(;
        width, length = len, threshold_voltage = 0.7 + 0.003z[3] / sqrt(area_um2),
        mobility = 0.04 * (1 + 0.01z[4] / sqrt(area_um2))
    )
    residual(v) = mosfet_operating_point(left, :nmos, 1.0, 1.0 + v / 2, 0.0, 0.0; temperature).id -
        mosfet_operating_point(right, :nmos, 1.0, 1.0 - v / 2, 0.0, 0.0; temperature).id
    lo, hi = -0.2, 0.2
    residual(lo) < 0 < residual(hi) || error("offset outside bracket")
    for _ in 1:42
        mid = (lo + hi) / 2
        if residual(mid) > 0
            hi = mid
        else
            lo = mid
        end
    end
    offset = (lo + hi) / 2
    result = operating_point(OffsetPair(; left, right, offset); temperature)
    result.stats[:converged] || error("pair bias failed")
    @assert isapprox(only(current(result, :MA, :drain)), only(current(result, :MB, :drain)); rtol = 1.0e-8)
    return (offset = offset, left = left, right = right, result = result)
end
# Reuse each random draw across conditions to track the same virtual pair.
seeds = rand(MersenneTwister(2026), UInt64, 32)
groups = map(Iterators.product([275.0, 350.0], [1.0e-6, 4.0e-6])) do (temperature, width)
    records = Any[]; samples = Union{Nothing, Float64}[]; failures = NamedTuple[]
    for seed in seeds
        try
            sample = offset_sample(width, 1.0e-6, temperature, randn(MersenneTwister(seed), 4))
            push!(records, sample); push!(samples, sample.offset)
        catch e
            e isa InterruptException && rethrow()
            push!(records, nothing); push!(samples, nothing)
            push!(failures, (seed = seed, message = sprint(showerror, e)))
        end
    end
    (
        temperature = temperature, width = width, length = 1.0e-6, samples = samples, seeds = seeds,
        records = records, failures = failures,
    )
end
mismatch = mismatchview(vec(groups))
@assert all(g -> g.failed == 0, mismatch.groups)
fig = Figure(size = (1300, 750)); mismatchplot(fig[1, 1], mismatch)
save(joinpath(output_dir, "36_cmos_offset_mismatch.png"), fig)
println("Saved CMOS studies to ", output_dir)
