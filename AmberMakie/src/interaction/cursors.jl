mutable struct CursorState{A, B, I, R, Q, S}
    a::A
    b::B
    interval::I
    readout::R
    interval_readout::Q
    subscriptions::S
end

function CursorState(x::AbstractVector, y::AbstractVector)
    isempty(x) && throw(ArgumentError("cursor data must not be empty"))
    a = Makie.Observable(float(first(x)))
    b = Makie.Observable(float(last(x)))
    interval = Makie.Observable(float(first(x)) => float(last(x)))
    readout = Makie.Observable(cursor_readout(x, y, a[], b[]))
    selected = Makie.Observable(interval_readout(x, y, interval[]))
    subscriptions = Any[]
    append!(
        subscriptions, Makie.onany(a, b) do avalue, bvalue
            readout[] = cursor_readout(x, y, avalue, bvalue)
        end
    )
    push!(
        subscriptions, Makie.on(interval) do bounds
            selected[] = interval_readout(x, y, bounds)
        end
    )
    return CursorState(a, b, interval, readout, selected, subscriptions)
end

setcursor!(state::CursorState, which::Symbol, value::Real) =
    which === :a ? (state.a[] = float(value)) : which === :b ? (state.b[] = float(value)) :
    throw(ArgumentError("cursor must be :a or :b"))

setinterval!(state::CursorState, interval::Pair) = (state.interval[] = float(first(interval)) => float(last(interval)))

function _cursor_axis!(axis, state::CursorState, x::AbstractVector)
    cursor_a = Makie.lift(state.a) do value
        [nearest_sample(x, x, value).x]
    end
    cursor_b = Makie.lift(state.b) do value
        [nearest_sample(x, x, value).x]
    end
    Makie.vlines!(axis, cursor_a; color = (_AMBER_COLORS.input, 0.8), linestyle = :dash)
    Makie.vlines!(axis, cursor_b; color = (_AMBER_COLORS.output, 0.8), linestyle = :dot)
    subscription = Makie.on(Makie.events(axis).mousebutton; priority = 10) do event
        event.button == Makie.Mouse.left && event.action == Makie.Mouse.press || return Makie.Consume(false)
        Makie.is_mouseinside(axis.scene) || return Makie.Consume(false)
        target = Makie.mouseposition(axis)[1]
        shifted = Makie.Keyboard.left_shift in Makie.events(axis).keyboardstate ||
            Makie.Keyboard.right_shift in Makie.events(axis).keyboardstate
        setcursor!(state, shifted ? :b : :a, target)
        Makie.Consume(true)
    end
    push!(state.subscriptions, subscription)
    return nothing
end

function _close!(state::CursorState)
    foreach(Makie.off, state.subscriptions)
    empty!(state.subscriptions)
    return nothing
end
