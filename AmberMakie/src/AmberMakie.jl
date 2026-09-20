module AmberMakie

import Amber
import Amber: switchingmetrics, _cmos_grid, _cmos_interp
import Makie
import LinearAlgebra
import TOML

export InverterView, inverterview, inverterplot, SwitchingView, switchingmetrics, switchingview, switchingplot, MismatchView, mismatchview, mismatchplot
export selectbias!, MOSFETView, mosfetview, mosfetplot, gmidplot, capacitanceplot
export TraceView, FrequencyView, SpectrumView, SpectrogramView, NoiseView, NoiseContributionView, NetworkView, EnsembleView, OperatingPointView, EyeDiagramView, JitterView
export traceview, frequencyview, spectrumview, spectrogramview, noiseview, noisecontributionview, networkview, ensembleview, operatingpointview, eyediagramview, jitterview, diagnosticgroups
export SpectrumCursorReadout, spectrum_cursor
export engineering, theme_amber_light, theme_amber_dark, theme_amber_publication
export PlotHandle, WorkbenchHandle, traceplot, bodeplot, spectrumplot, harmonicplot
export eyediagramplot, jitterplot, transfercharacteristicplot, sensitivityplot, yieldmapplot
export spectrogramplot, noiseplot, noisecontributionplot, noisebudgetplot, integratednoiseplot, phasenoiseplot, periodicnoiseplot, workbench
export nyquistplot, nicholsplot, polezeroplot, rootlocusplot, marginplot, groupdelayplot
export networkplot, smithplot, stabilitycircleplot, mixedmodeplot, impedanceplot
export SmithCursorReadout, smith_cursor_readout
export pssplot, orbitplot, operatingpointplot, diagnosticplot
export safeoperatingareaplot, powerdashboard, poleparticipationplot, waterfallplot
export FloquetModeReadout, floquet_mode
export sweepplot, ensembleplot, correlationplot, compareplot
export yieldplot, failureplot, parametermatrixplot, sampleplot
export rank_correlation, selectsample!, replay_sample!, selectcomponent!, selectsignal!
export isolatetrace!, toggletrace!, showalltraces!, helptext
export outlier_samples
export StudyHandle, explore, runstudy!, setparameter!, pin!
export savefigure, copyrecipe
export reportfigure
export CursorSample, CursorReadout, CursorState, IntervalReadout
export nearest_sample, cursor_readout, interval_readout, setcursor!, setinterval!

include("adapters.jl")
include("formatting.jl")
include("themes.jl")
include("handles.jl")
include("interaction/measurements.jl")
include("interaction/cursors.jl")
include("recipes/transient.jl")
include("recipes/frequency.jl")
include("recipes/spectrum.jl")
include("recipes/noise.jl")
include("recipes/control.jl")
include("recipes/network.jl")
include("recipes/periodic.jl")
include("recipes/statistics.jl")
include("recipes/diagnostics.jl")
include("workbenches/result.jl")
include("recipes/cmos.jl")
include("recipes/cmos_studies.jl")
include("workbenches/study.jl")
include("export.jl")

end
