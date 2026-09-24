# Run this same script with --project pointing at each revision.
using Amber, LinearAlgebra, TOML
@subcircuit CompareCell(input, output, reference) begin
    R = resistor(input, output; value = 1.0e3)
    C = capacitor(output, reference; value = 1.0e-12)
end
function design(cells, mos)
    b = CircuitBuilder(:Comparison); g = ground!(b, :gnd); x = node_array!(b, :x, 0:cells)
    add!(b, voltage_source(x[0], g; dc = 0.8, ac = 1.0); name = :Source)
    instances!(b, CompareCell, 1:cells; name = i -> (:cell, i), connections = i -> (input = x[i - 1], output = x[i], reference = g))
    if mos
        model = ChargeBasedMOSFET()
        for i in 1:cells
            add!(b, nmos(x[i], x[0], g, g; model); name = (:M, i))
        end
    end
    return finish(b)
end
function measure(f; repeats = 30)
    f(); elapsed = Inf; bytes = 0
    for _ in 1:repeats
        result = @timed f()
        if result.time < elapsed
            elapsed = result.time; bytes = result.bytes
        end
    end
    return Dict("seconds" => elapsed, "bytes" => bytes)
end
function compare(cells, mos)
    d = design(cells, mos); cc = compile(d); ws = SimulationWorkspace(cc)
    x = fill(0.4, cc.n); q = Amber._storage(cc, x .- 0.001); alpha = 1.0e6
    values = Dict{String, Any}(
        "compile" => measure(() -> compile(d); repeats = 5),
        "step_jacobian" => measure(() -> Amber._step_residual_jacobian!(ws, cc, x, q, 0.0, alpha)),
        "parameter_update" => measure(() -> with_parameters(cc, "cell[1:$(cells)].R.value" => 2.0e3)),
        "ac" => measure(() -> small_signal(cc, 10.0 .^ range(1, 6; length = 40)); repeats = 3)
    )
    if isdefined(Amber, :_step_residual!)
        values["line_search_residual"] = measure(() -> Amber._step_residual!(ws, cc, x, q, 0.0, alpha))
        handle = parameter_handle(cc, "cell[1:$(cells)].R.value")
        values["resolved_update"] = measure(() -> with_parameters(cc, handle => 2.0e3))
    else
        values["line_search_residual"] = values["step_jacobian"]
    end
    return values
end
cells = parse(Int, get(ENV, "AMBER_BENCH_CELLS", "100"))
TOML.print(
    stdout, Dict(
        "cells" => cells, "julia_version" => string(VERSION), "threads" => Threads.nthreads(),
        "passive" => compare(cells, false), "cmos" => compare(cells, true)
    ); sorted = true
)
