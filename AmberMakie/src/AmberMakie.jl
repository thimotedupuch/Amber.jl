module AmberMakie

import Amber
import Makie

export TraceView, FrequencyView, SpectrumView, NoiseView, NetworkView, EnsembleView
export traceview, frequencyview, spectrumview, noiseview, networkview, ensembleview
export engineering, theme_amber_light, theme_amber_dark, theme_amber_publication
export PlotHandle, WorkbenchHandle, traceplot, bodeplot, spectrumplot, harmonicplot
export noiseplot, workbench
export nyquistplot, nicholsplot, polezeroplot, rootlocusplot, marginplot, groupdelayplot
export networkplot, smithplot, stabilitycircleplot, mixedmodeplot
export pssplot, orbitplot, operatingpointplot, diagnosticplot
export sweepplot, ensembleplot, correlationplot, compareplot
export StudyHandle, explore, runstudy!, setparameter!, pin!
export savefigure, copyrecipe
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
include("workbenches/study.jl")
include("export.jl")

end
