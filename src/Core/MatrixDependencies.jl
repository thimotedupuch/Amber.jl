# These are the coefficients actually consumed by the existing constant kernels.
# Unknown future linear kernels conservatively compare complete parameter data.
_constant_matrix_fields(::Val{K}) where K = device_contract(K).dependencies.matrix_fields
_constant_matrix_equal(old::ResistorBatch,new::ResistorBatch) = isequal(old.conductance,new.conductance)
function _constant_matrix_equal(old::PrimitiveBatch{K},new::PrimitiveBatch{K}) where K
    _linear_batch(old) || return true
    fields=_constant_matrix_fields(K())
    fields === nothing && return isequal(old.parameters,new.parameters)
    length(old.parameters) == length(new.parameters) || return false
    for index in eachindex(old.parameters), field in fields
        isequal(get(old.parameters[index],field,nothing),get(new.parameters[index],field,nothing)) || return false
    end
    return true
end
_constant_matrix_equal(old,new) = false
function _updated_matrix_identity(store,batches,matrix_changed)
    for index in eachindex(batches)
        matrix_changed[index] || continue
        _constant_matrix_equal(store.batches[index],batches[index]) || return MatrixCacheIdentity()
    end
    return store.matrix_identity
end
