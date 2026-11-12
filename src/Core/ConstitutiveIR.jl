# Experimental local equation IR. Circuit topology and numerical kernels continue
# to use the established batch backend until this representation is qualified.
abstract type ConstitutiveExpr end
struct EquationLiteral{T} <: ConstitutiveExpr
    value::T
end
struct EquationInput{Name} <: ConstitutiveExpr end
struct EquationCall{Op,A<:Tuple} <: ConstitutiveExpr
    arguments::A
end
_equation_expr(x::ConstitutiveExpr) = x
_equation_expr(x::Number) = EquationLiteral(x)
_equation_call(::Val{Op}, args...) where Op = EquationCall{Op,typeof(args)}(args)
for op in (:+, :-, :*, :/)
    @eval begin
        Base.$op(a::ConstitutiveExpr, b::ConstitutiveExpr) = _equation_call(Val($(QuoteNode(op))), a, b)
        Base.$op(a::ConstitutiveExpr, b::Number) = $op(a, EquationLiteral(b))
        Base.$op(a::Number, b::ConstitutiveExpr) = $op(EquationLiteral(a), b)
    end
end
Base.:-(a::ConstitutiveExpr) = EquationLiteral(-1) * a
Base.exp(a::ConstitutiveExpr) = _equation_call(Val(:exp), a)
Base.log1p(a::ConstitutiveExpr) = _equation_call(Val(:log1p), a)
Base.:^(a::ConstitutiveExpr, b::Real) = _equation_call(Val(:power), a, EquationLiteral(b))
# Lazy branch: the unselected expression may be undefined at this input.
_equation_positive(test, positive, otherwise) = _equation_call(Val(:positive), test, positive, otherwise)

_equation_value(x::EquationLiteral, inputs) = x.value
_equation_value(::EquationInput{Name}, inputs) where Name = getproperty(inputs, Name)
function _equation_value(x::EquationCall{Op}, inputs) where Op
    a = x.arguments
    Op === :positive && return _equation_value(a[1], inputs) > 0 ?
        _equation_value(a[2], inputs) : _equation_value(a[3], inputs)
    values = map(y -> _equation_value(y, inputs), a)
    Op === :+ && return +(values...)
    Op === :- && return -(values...)
    Op === :* && return *(values...)
    Op === :/ && return /(values...)
    Op === :exp && return exp(only(values))
    Op === :log1p && return log1p(only(values))
    Op === :power && return values[1]^values[2]
    error("unsupported equation operation $Op")
end

# Small local simplifier. Deliberately no reassociation or fast-math rewrites.
_equation_zero(x) = x isa EquationLiteral && iszero(x.value)
_equation_one(x) = x isa EquationLiteral && isone(x.value)
function _equation_sum(a, b)
    _equation_zero(a) && return b
    _equation_zero(b) && return a
    return a + b
end
function _equation_product(a, b)
    (_equation_zero(a) || _equation_zero(b)) && return EquationLiteral(0)
    _equation_one(a) && return b
    _equation_one(b) && return a
    return a * b
end
_equation_derivative(::EquationLiteral, ::Val) = EquationLiteral(0)
_equation_derivative(::EquationInput{Name}, ::Val{Variable}) where {Name,Variable} = EquationLiteral(Int(Name === Variable))
function _equation_derivative(x::EquationCall{Op}, variable::Val) where Op
    a = x.arguments
    if Op === :positive
        return _equation_positive(a[1], _equation_derivative(a[2], variable), _equation_derivative(a[3], variable))
    end
    da = _equation_derivative(a[1], variable)
    Op === :exp && return _equation_product(exp(a[1]), da)
    Op === :log1p && return _equation_zero(da) ? da : da / (1 + a[1])
    if Op === :power
        exponent = a[2].value
        (iszero(exponent) || _equation_zero(da)) && return EquationLiteral(0)
        return _equation_product(EquationLiteral(exponent), _equation_product(a[1]^(exponent-1), da))
    end
    db = _equation_derivative(a[2], variable)
    Op === :+ && return _equation_sum(da, db)
    Op === :- && return _equation_sum(da, _equation_product(EquationLiteral(-1), db))
    Op === :* && return _equation_sum(_equation_product(da, a[2]), _equation_product(a[1], db))
    if Op === :/
        numerator = _equation_sum(_equation_product(da, a[2]), _equation_product(EquationLiteral(-1), _equation_product(a[1], db)))
        return _equation_zero(numerator) ? numerator : numerator / (a[2] * a[2])
    end
    error("no derivative rule for $Op")
end

_equation_inputs(::EquationLiteral) = ()
_equation_inputs(::EquationInput{Name}) where Name = (Name,)
_equation_inputs(x::EquationCall) = Tuple(unique(collect(Iterators.flatten(map(_equation_inputs, x.arguments)))))

"""Local static-current and stored-charge equations, before global MNA stamping.

Internal experimental API. Expressions operate on numeric SI inputs. Branch
predicates have piecewise derivatives; no impulse or distributional terms are
introduced at a discontinuity. Topology transformations are not enabled.
"""
struct ConstitutiveLaw{F<:ConstitutiveExpr,Q<:ConstitutiveExpr}
    current::F
    charge::Q
end
struct ConstitutiveKernel{L,D}
    law::L
    derivatives::D
end
function _constitutive_kernel(law::ConstitutiveLaw, variables::Tuple)
    length(unique(variables)) == length(variables) || throw(ArgumentError("duplicate derivative variables"))
    derivatives = NamedTuple{variables}(map(name -> (
        current=_equation_derivative(law.current, Val(name)),
        charge=_equation_derivative(law.charge, Val(name))), variables))
    return ConstitutiveKernel(law, derivatives)
end
function _constitutive_value(kernel::ConstitutiveKernel, inputs::NamedTuple)
    values = (; current=_equation_value(kernel.law.current, inputs), charge=_equation_value(kernel.law.charge, inputs))
    derivatives = map(d -> (; current=_equation_value(d.current, inputs), charge=_equation_value(d.charge, inputs)), kernel.derivatives)
    return (; values..., derivatives)
end

# Complete existing diode conduction law, including both exponential continuations
# and avalanche onset. Charge is deliberately not represented by this prototype.
function _diode_conduction_ir(model::JunctionDiode)
    v = EquationInput{:voltage}(); temperature = EquationInput{:temperature}()
    saturation = EquationInput{:saturation_current}()
    vt = (1.380649e-23 / 1.602176634e-19 * model.ideality) * temperature
    function limited(x)
        _equation_positive(x - 80, exp(80.0) * (1 + x - 80) - 1,
            _equation_positive(-80 - x, EquationLiteral(exp(-80.0) - 1), exp(x) - 1))
    end
    conduction = saturation * limited(v / vt)
    if isfinite(model.breakdown_voltage)
        argument = (-v - model.breakdown_voltage) / vt
        conduction -= _equation_positive(argument, model.breakdown_current * limited(argument), EquationLiteral(0))
    end
    return ConstitutiveLaw(conduction, EquationLiteral(0))
end


"""Complete local diode current/charge law, using the production continuation rules.

Model options are construction-time literals; voltage, temperature and saturation
current are runtime inputs. No production assembly kernel is replaced.
"""
function _diode_constitutive_ir(model::JunctionDiode)
    conduction = _diode_conduction_ir(model).current
    v = EquationInput{:voltage}(); temperature = EquationInput{:temperature}()
    saturation = EquationInput{:saturation_current}()
    vt = (1.380649e-23 / 1.602176634e-19 * model.ideality) * temperature
    argument = v / vt
    forward = _equation_positive(argument - 80,
        exp(80.0) * (1 + argument - 80) - 1,
        _equation_positive(-80 - argument, EquationLiteral(exp(-80.0)-1), exp(argument)-1))
    diffusion = model.transit_time * saturation * forward
    capacitance = model.junction_capacitance
    if iszero(capacitance)
        return ConstitutiveLaw(conduction, diffusion)
    end
    potential = model.junction_potential; grading = model.grading_coefficient
    transition = 0.9potential
    function depletion(x)
        abs(1-grading) < 1e-12 ? -capacitance * potential * log1p(-x/potential) :
            capacitance * potential / (1-grading) * (1-(1-x/potential)^(1-grading))
    end
    continuation = depletion(transition) + capacitance * (1-transition/potential)^(-grading) * (v-transition)
    stored = _equation_positive(v-transition, continuation, depletion(v)) + diffusion
    return ConstitutiveLaw(conduction, stored)
end
