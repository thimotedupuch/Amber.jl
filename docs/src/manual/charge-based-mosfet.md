# Charge-based MOSFET

`ChargeBasedMOSFET` is Amber's native, quasi-static long-channel MOS model for
programmatic analog experiments. It provides continuous weak, moderate and
strong inversion, symmetric source/drain transport, geometry scaling,
Ward–Dutton channel-charge partition, optional junctions and overlaps, and
explicit temperature laws. It is a bounded charge-based model, **not a full EKV
implementation, a SPICE Level 2 model, or a foundry model-card implementation**.
Defaults are illustrative and do not represent a fabrication process.

## Geometry and characterization

```@example charge_mos
using Amber
technology = ChargeBasedMOSFET(
    threshold_voltage=0.7V,
    slope_factor=1.3,
    mobility=0.04,                 # m²/(V s)
    oxide_capacitance=5e-3,         # F/m²
    channel_length_modulation=0.02/V,
)
transistor = with_model_parameter(technology, :width, 8μm)
transistor = with_model_parameter(transistor, :length, 2μm)
points = [mosfet_operating_point(transistor, :nmos, 1.2V, vg, 0V, 0V)
          for vg in range(0.2V, 1.4V; length=61)]
table = [(; gate_voltage=vg, id=p.id, gm_over_id=p.gm_over_id,
           intrinsic_gain=p.intrinsic_gain)
         for (vg,p) in zip(range(0.2V, 1.4V; length=61),points)]
first(table)
```

`mosfet_operating_point` also returns signed `gm`, `gds`, `gmb`, terminal
currents, terminal charges, normalized endpoint inversion charges, and the
4×4 `capacitance_matrix = ∂Qᵢ/∂Vⱼ`. Matrix order is drain, gate, source, bulk;
these are signed derivatives, not four positive pairwise capacitor values.
`id` is channel current; `currents.drain` includes the body junction.
Ratios use magnitudes and return `NaN` for a zero denominator.

```@example charge_mos
@circuit BiasExperiment() begin
    gnd=ground(); drain=node(); gate=node()
    VD=voltage_source(drain,gnd;dc=1.2V)
    VG=voltage_source(gate,gnd;dc=1V,ac=1V)
    M1=nmos(drain,gate,gnd,gnd;model=technology,width=8μm,length=2μm)
end
compiled=compile(BiasExperiment())
op=operating_point(compiled;temperature=320K)
mosfet_operating_point(op,:M1)
```

Geometry keywords create an instance-specific immutable model copy. Numerical
updates such as `with_parameters(compiled, "M1.width" => 12μm)` share topology.
`terminal_charges(op, :M1)` returns named charge traces; AC results return charge
phasors linearized at the DC bias. Continuous inversion has no categorical
cutoff boundary, so `region` directs callers to `mosfet_operating_point`.

## Equations and numerical contract

Normalize physical voltages by polarity (+1 for NMOS, −1 for PMOS), with bulk
as reference. For slope factor ``n`` and thermal voltage ``U_T``, the normalized
endpoint charges satisfy

```math
2q_s+\log q_s=\frac{(V_{GB}-V_T)/n-V_{SB}}{U_T},\qquad
2q_d+\log q_d=\frac{(V_{GB}-V_T)/n-V_{DB}}{U_T}.
```

With ``\beta=\mu C_{ox}(W/L)m``, normalized channel current is

```math
I_D=2n\beta U_T^2(q_s-q_d)(q_s+q_d+1).
```

Optional empirical channel-length modulation multiplies this by
``1+\lambda(\sqrt{V_{DS}^2+U_T^2}-U_T)``. It is smooth at source/drain reversal.
The default is zero; saturated intrinsic gain can consequently be very large.

Along normalized channel position ``x``, ``q(x)^2+q(x)`` interpolates linearly
between endpoint values. Source and drain charges integrate the inversion
charge density ``-2nC_{ox}U_Tq(x)`` with weights ``1-x`` and ``x``. Closed-form
polynomials avoid a removable singularity at equal endpoint charges. The gate
balances total inversion charge. Intrinsic depletion/accumulation bulk charge
is omitted; bulk charge comes from optional junctions and gate/bulk capacitance.
The constant slope factor gives a simplified bulk coupling, not a nonlinear
surface-potential/body-effect model.

The charge-domain transport and partition approach follows the formulation
explained by Christian Enz in [The EKV MOSFET Transistor Small-signal Model](https://ekvmodel.com/notebooks/Intrinsic%20capacitances/Intrinsic_capacitances.html).
Amber uses its own explicit constant-slope endpoint law and bounded additions.

All four terminal currents and charges conserve their sums. Analytic first and
second derivatives are propagated together. Amber's DAE stamps
``I(v)+Q_v(v)\dot v`` and its full Newton derivative, including
``Q_{vv}\dot v``. BDF integrates terminal voltages; it does not directly take
finite differences of nonlinear charge. Integrated charge-transfer accuracy
therefore requires timestep refinement. AC uses the same ``Q_v`` at the bias.

## Parameters and limits

| Parameters | Meaning |
|---|---|
| `width`, `length`, `multiplicity` | Positive geometry in metres; multiplicity scales current and charge |
| `mobility`, `oxide_capacitance` | Positive reference mobility (m²/V/s), oxide density (F/m²) |
| `threshold_voltage`, `slope_factor` | Polarity-normalized threshold (V), constant slope factor ≥1 |
| `reference_temperature` | Reference temperature in kelvin |
| `threshold_temperature_coefficient` | Linear threshold shift (V/K) |
| `mobility_temperature_exponent` | Power in μ(T)=μref(T/Tref)^exponent |
| `channel_length_modulation` | Non-negative empirical coefficient (1/V) |
| `gate_source_overlap`, `gate_drain_overlap` | Overlap capacitance per width (F/m) |
| `gate_bulk_capacitance` | Fixed gate/bulk capacitance (F), before multiplicity |
| `drain_area`, `source_area` | Explicit junction areas (m²); default zero |
| `drain_perimeter`, `source_perimeter` | Explicit junction perimeters (m); default zero |
| `junction_capacitance_density`, `junction_sidewall_capacitance` | Zero-bias junction densities (F/m², F/m) |
| `junction_potential`, `junction_grading` | Depletion law parameters (V, dimensionless) |
| `junction_saturation_current_density` | Area-scaled diode current density (A/m²) at analysis temperature |

Junction geometry is never inferred from W/L. Positive forward junction current
flows from bulk to NMOS diffusion, with PMOS polarity reversed. Depletion charge
continues linearly above 90% of junction potential. Junction current has an
exponential continuation for Newton robustness; breakdown and diffusion charge
are absent. No saturation-current temperature law is inferred.

Channel thermal noise uses ``4kT\mu|Q_I|/L^2``, scaled by
`channel_thermal_coefficient` (default 1). At zero drain bias this recovers the
channel conductance noise. Flicker and optional correlated gate noise use the
existing empirical MOS noise parameters; they are not process-calibrated.
Junction shot noise is currently omitted and reported in noise validity warnings.

Velocity saturation, mobility degradation with vertical field, DIBL, nonlinear
body effect, non-quasi-static transport, self-heating and layout-dependent effects
are outside this model. PSS/noise analyses inherit these physical limits.
