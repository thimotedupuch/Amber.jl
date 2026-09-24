const _AMBER_COLORS = (
    input = "#0072B2", output = "#D55E00", voltage = "#0072B2",
    current = "#009E73", power = "#CC79A7", warning = "#E69F00",
    invalid = "#D55E00", nominal = "#0072B2", candidate = "#009E73",
)

theme_amber_light() = Makie.Theme(
    backgroundcolor = :white,
    textcolor = :black,
    Axis = (backgroundcolor = :white, xgridcolor = (:black, 0.1), ygridcolor = (:black, 0.1)),
    palette = (color = unique(collect(values(_AMBER_COLORS))),),
)

theme_amber_dark() = Makie.Theme(
    backgroundcolor = "#15171A",
    textcolor = "#F2F2F2",
    Axis = (backgroundcolor = "#15171A", xgridcolor = (:white, 0.12), ygridcolor = (:white, 0.12)),
    palette = (color = unique(collect(values(_AMBER_COLORS))),),
)

theme_amber_publication() = Makie.merge(
    theme_amber_light(), Makie.Theme(
        fontsize = 11,
        linewidth = 1.5,
        Axis = (titlesize = 12, xlabelsize = 11, ylabelsize = 11),
    )
)
