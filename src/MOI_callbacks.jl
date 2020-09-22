# ==============================================================================
#    Generic Callbacks in Gurobi
# ==============================================================================

mutable struct CallbackData
    ptr::Ptr{Cvoid}
end
Base.cconvert(::Type{Ptr{Cvoid}}, x::CallbackData) = x
Base.unsafe_convert(::Type{Ptr{Cvoid}}, x::CallbackData) = x.ptr::Ptr{Cvoid}

mutable struct _CallbackUserData
    callback::Function
end
Base.cconvert(::Type{Ptr{Cvoid}}, x::_CallbackUserData) = x
function Base.unsafe_convert(::Type{Ptr{Cvoid}}, x::_CallbackUserData)
    return pointer_from_objref(x)::Ptr{Cvoid}
end

function gurobi_callback_wrapper(
    ::Ptr{Cvoid},
    cb_data::Ptr{Cvoid},
    cb_where::Cint,
    p_user_data::Ptr{Cvoid}
)
    user_data = unsafe_pointer_to_objref(p_user_data)::_CallbackUserData
    user_data.callback(CallbackData(cb_data), cb_where)
    return Cint(0)
end

"""
    CallbackFunction()

Set a generic Gurobi callback function.

Callback function should be of the form

    callback(cb_data::CallbackData, cb_where::Cint)

Note: before accessing `MOI.CallbackVariablePrimal`, you must call either
`Gurobi.cbget_mipsol_sol(model, cb_data, cb_where)` or
`Gurobi.cbget_mipsol_rel(model, cb_data, cb_where)`.
"""
struct CallbackFunction <: MOI.AbstractCallback end

function MOI.set(model::Optimizer, ::CallbackFunction, f::Function)
    grb_callback = @cfunction(
        gurobi_callback_wrapper,
        Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Ptr{Cvoid})
    )
    user_data = _CallbackUserData(
        (cb_data, cb_where) -> begin
            model.callback_state = CB_GENERIC
            f(cb_data, cb_where)
            model.callback_state = CB_NONE
            return
        end
    )
    ret = GRBsetcallbackfunc(model, grb_callback, user_data)
    _check_ret(model, ret)
    # We need to keep a reference to the callback function so that it isn't
    # garbage collected.
    model.generic_callback = user_data
    model.has_generic_callback = true
    # Mark the update as necessary and immediately call for the update.
    _require_update(model)
    _update_if_necessary(model)
    return
end
MOI.supports(::Optimizer, ::CallbackFunction) = true

"""
    cbget_mipsol_sol(model::Optimizer, cb_data, cb_where)

Load the solution at a `GRB_CB_MIPSOL` node so that it can be accessed using
`MOI.CallbackVariablePrimal`.
"""
function cbget_mipsol_sol(model::Optimizer, cb_data, cb_where)
    resize!(model.callback_variable_primal, length(model.variable_info))
    ret = GRBcbget(
        cb_data, cb_where, GRB_CB_MIPSOL_SOL, model.callback_variable_primal
    )
    _check_ret(model, ret)
    return
end

"""
    cbget_mipsol_rel(model::Optimizer, cb_data, cb_where)

Load the solution at a `GRB_CB_MIPNODE` node so that it can be accessed using
`MOI.CallbackVariablePrimal`.
"""
function cbget_mipsol_rel(model::Optimizer, cb_data, cb_where)
    resize!(model.callback_variable_primal, length(model.variable_info))
    ret = GRBcbget(
        cb_data, cb_where, GRB_CB_MIPNODE_REL, model.callback_variable_primal
    )
    _check_ret(model, ret)
    return
end

# ==============================================================================
#    MOI callbacks
# ==============================================================================

function default_moi_callback(model::Optimizer)
    return (cb_data, cb_where) -> begin
        if cb_where == GRB_CB_MIPSOL
            cbget_mipsol_sol(model, cb_data, cb_where)
            if model.lazy_callback !== nothing
                model.callback_state = CB_LAZY
                model.lazy_callback(cb_data)
            end
        elseif cb_where == GRB_CB_MIPNODE
            resultP = Ref{Cint}()
            GRBcbget(cb_data, cb_where, GRB_CB_MIPNODE_STATUS, resultP)
            if resultP[] != 2
                return  # Solution is something other than optimal.
            end
            cbget_mipsol_rel(model, cb_data, cb_where)
            if model.lazy_callback !== nothing
                model.callback_state = CB_LAZY
                model.lazy_callback(cb_data)
            end
            if model.user_cut_callback !== nothing
                model.callback_state = CB_USER_CUT
                model.user_cut_callback(cb_data)
            end
            if model.heuristic_callback !== nothing
                model.callback_state = CB_HEURISTIC
                model.heuristic_callback(cb_data)
            end
        end
        model.callback_state = CB_NONE
    end
end

function MOI.get(
    model::Optimizer,
    ::MOI.CallbackVariablePrimal{CallbackData},
    x::MOI.VariableIndex
)
    return model.callback_variable_primal[_info(model, x).column]
end

# ==============================================================================
#    MOI.LazyConstraint
# ==============================================================================

function MOI.set(model::Optimizer, ::MOI.LazyConstraintCallback, cb::Function)
    MOI.set(model, MOI.RawParameter("LazyConstraints"), 1)
    model.lazy_callback = cb
    return
end
MOI.supports(::Optimizer, ::MOI.LazyConstraintCallback) = true

function MOI.submit(
    model::Optimizer,
    cb::MOI.LazyConstraint{CallbackData},
    f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64}}
)
    if model.callback_state == CB_USER_CUT
        throw(MOI.InvalidCallbackUsage(MOI.UserCutCallback(), cb))
    elseif model.callback_state == CB_HEURISTIC
        throw(MOI.InvalidCallbackUsage(MOI.HeuristicCallback(), cb))
    elseif !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    ret = GRBcblazy(
        cb.callback_data,
        length(indices),
        indices,
        coefficients,
        sense,
        rhs,
    )
    _check_ret(model, ret)
    return
end
MOI.supports(::Optimizer, ::MOI.LazyConstraint{CallbackData}) = true

# ==============================================================================
#    MOI.UserCutCallback
# ==============================================================================

function MOI.set(model::Optimizer, ::MOI.UserCutCallback, cb::Function)
    model.user_cut_callback = cb
    return
end
MOI.supports(::Optimizer, ::MOI.UserCutCallback) = true

function MOI.submit(
    model::Optimizer,
    cb::MOI.UserCut{CallbackData},
    f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64}}
)
    if model.callback_state == CB_LAZY
        throw(MOI.InvalidCallbackUsage(MOI.LazyConstraintCallback(), cb))
    elseif model.callback_state == CB_HEURISTIC
        throw(MOI.InvalidCallbackUsage(MOI.HeuristicCallback(), cb))
    elseif !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    ret = GRBcbcut(
        cb.callback_data,
        length(indices),
        indices,
        coefficients,
        sense,
        rhs,
    )
    _check_ret(model, ret)
    return
end
MOI.supports(::Optimizer, ::MOI.UserCut{CallbackData}) = true

# ==============================================================================
#    MOI.HeuristicCallback
# ==============================================================================

function MOI.set(model::Optimizer, ::MOI.HeuristicCallback, cb::Function)
    model.heuristic_callback = cb
    return
end
MOI.supports(::Optimizer, ::MOI.HeuristicCallback) = true

function MOI.submit(
    model::Optimizer,
    cb::MOI.HeuristicSolution{CallbackData},
    variables::Vector{MOI.VariableIndex},
    values::MOI.Vector{Float64}
)
    if model.callback_state == CB_LAZY
        throw(MOI.InvalidCallbackUsage(MOI.LazyConstraintCallback(), cb))
    elseif model.callback_state == CB_USER_CUT
        throw(MOI.InvalidCallbackUsage(MOI.UserCutCallback(), cb))
    end
    solution = fill(GRB_UNDEFINED, MOI.get(model, MOI.NumberOfVariables()))
    for (var, value) in zip(variables, values)
        solution[_info(model, var).column] = value
    end
    objP = Ref{Cdouble}()
    ret = GRBcbsolution(cb.callback_data, solution, objP)
    _check_ret(model, ret)
    return objP[] < GRB_INFINITY ? MOI.HEURISTIC_SOLUTION_ACCEPTED : MOI.HEURISTIC_SOLUTION_REJECTED
end
MOI.supports(::Optimizer, ::MOI.HeuristicSolution{CallbackData}) = true
