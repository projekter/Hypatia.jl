#=
epigraph of the relative entropy cone
(u in R, V in S_+^d, W in S_+^d) : u >= tr(W * log(W) - W * log(V))

derivatives for quantum relative entropy function adapted from
"Long-Step Path-Following Algorithm in Quantum Information Theory: Some Numerical Aspects and Applications"
by L. Faybusovich and C. Zhou

uses the log-homogeneous but not self-concordant barrier
-log(u - tr(W * log(W) - W * log(V))) - logdet(W) - logdet(V)

TODO reduce allocations
=#

mutable struct EpiTraceRelEntropyTri{T <: Real} <: Cone{T}
    use_dual_barrier::Bool
    use_heuristic_neighborhood::Bool
    dim::Int
    d::Int

    point::Vector{T}
    dual_point::Vector{T}
    grad::Vector{T}
    correction::Vector{T}
    vec1::Vector{T}
    vec2::Vector{T}
    feas_updated::Bool
    grad_updated::Bool
    hess_updated::Bool
    inv_hess_updated::Bool
    hess_fact_updated::Bool
    is_feas::Bool
    hess::Symmetric{T, Matrix{T}}
    inv_hess::Symmetric{T, Matrix{T}}
    hess_fact_cache

    # TODO type fields
    rt2::T
    V
    W
    Vi
    Wi
    V_idxs
    W_idxs
    vw_dim
    z
    dzdV
    dzdW
    W_similar
    mat
    matsdim1
    matsdim2
    tempsdim
    diff_mat_V
    diff_mat_W
    V_fact
    W_fact
    V_vals_log
    W_vals_log
    V_log
    W_log
    WV_log

    function EpiTraceRelEntropyTri{T}(
        dim::Int;
        use_dual::Bool = false,
        use_heuristic_neighborhood::Bool = default_use_heuristic_neighborhood(),
        hess_fact_cache = hessian_cache(T),
        ) where {T <: Real}
        @assert dim > 2
        cone = new{T}()
        cone.use_dual_barrier = use_dual
        cone.use_heuristic_neighborhood = use_heuristic_neighborhood
        cone.dim = dim
        cone.vw_dim = div(dim - 1, 2)
        cone.d = round(Int, sqrt(0.25 + 2 * cone.vw_dim) - 0.5)
        cone.hess_fact_cache = hess_fact_cache
        return cone
    end
end

use_correction(::EpiTraceRelEntropyTri) = false # TODO

function setup_extra_data(cone::EpiTraceRelEntropyTri{T}) where {T <: Real}
    dim = cone.dim
    cone.hess = Symmetric(zeros(T, dim, dim), :U)
    cone.inv_hess = Symmetric(zeros(T, dim, dim), :U)
    load_matrix(cone.hess_fact_cache, cone.hess)
    d = cone.d
    cone.rt2 = sqrt(T(2))
    cone.V = zeros(T, d, d)
    cone.W = zeros(T, d, d)
    cone.Vi = zeros(T, d, d)
    cone.Wi = zeros(T, d, d)
    cone.V_idxs = 2:(cone.vw_dim + 1)
    cone.W_idxs = (cone.vw_dim + 2):cone.dim
    cone.dzdV = zeros(T, cone.vw_dim)
    cone.dzdW = zeros(T, cone.vw_dim)
    cone.W_similar = zeros(T, d, d)
    cone.mat = zeros(T, d, d)
    cone.matsdim1 = zeros(T, cone.vw_dim, cone.vw_dim)
    cone.matsdim2 = zeros(T, cone.vw_dim, cone.vw_dim)
    cone.tempsdim = zeros(T, cone.vw_dim)
    cone.diff_mat_V = zeros(T, d, d)
    cone.diff_mat_W = zeros(T, d, d)
    cone.V_vals_log = zeros(T, d)
    cone.W_vals_log = zeros(T, d)
    cone.V_log = zeros(T, d, d)
    cone.W_log = zeros(T, d, d)
    cone.WV_log = zeros(T, d, d)
    return
end

get_nu(cone::EpiTraceRelEntropyTri) = 2 * cone.d + 1

function set_initial_point(arr::AbstractVector, cone::EpiTraceRelEntropyTri{T}) where {T <: Real}
    arr .= 0
    # at the initial point V and W are diagonal, equivalent to epirelentropy
    (arr[1], v, w) = get_central_ray_epirelentropy(cone.d)
    k = 1
    for i in 1:cone.d
        arr[1 + k] = v
        arr[cone.vw_dim + 1 + k] = w
        k += i + 1
    end
    return arr
end

function update_feas(cone::EpiTraceRelEntropyTri{T}) where {T <: Real}
    @assert !cone.feas_updated
    point = cone.point
    vw_dim = cone.vw_dim
    @views V = Hermitian(svec_to_smat!(cone.V, point[cone.V_idxs], cone.rt2), :U)
    @views W = Hermitian(svec_to_smat!(cone.W, point[cone.W_idxs], cone.rt2), :U)

    cone.is_feas = false
    (V_vals, V_vecs) = cone.V_fact = eigen(V)
    if isposdef(cone.V_fact)
        (W_vals, W_vecs) = cone.W_fact = eigen(W)
        if isposdef(cone.W_fact)
            @. cone.V_vals_log = log(V_vals)
            @. cone.W_vals_log = log(W_vals)
            mul!(cone.mat, V_vecs, Diagonal(cone.V_vals_log))
            V_log = mul!(cone.V_log, cone.mat, V_vecs')
            mul!(cone.mat, W_vecs, Diagonal(cone.W_vals_log))
            W_log = mul!(cone.W_log, cone.mat, W_vecs')
            @. cone.WV_log = W_log - V_log
            cone.z = point[1] - dot(W, Hermitian(cone.WV_log, :U))
            cone.is_feas = (cone.z > 0)
        end
    end

    cone.feas_updated = true
    return cone.is_feas
end

is_dual_feas(::EpiTraceRelEntropyTri) = true

function update_grad(cone::EpiTraceRelEntropyTri{T}) where {T <: Real}
    @assert cone.is_feas
    d = cone.d
    rt2 = cone.rt2
    V_idxs = cone.V_idxs
    W_idxs = cone.W_idxs
    W = Hermitian(cone.W, :U)
    z = cone.z
    (V_vals, V_vecs) = cone.V_fact
    (W_vals, W_vecs) = cone.W_fact
    ldiv!(cone.mat, Diagonal(V_vals), V_vecs')
    Vi = mul!(cone.Vi, V_vecs, cone.mat)
    ldiv!(cone.mat, Diagonal(W_vals), W_vecs')
    Wi = mul!(cone.Wi, W_vecs, cone.mat)

    cone.grad[1] = -inv(z)

    dzdW = cone.dzdW = -(cone.WV_log + I) / z
    grad_W = -dzdW - Wi
    @views smat_to_svec!(cone.grad[W_idxs], grad_W, rt2)

    diff_mat_V = cone.diff_mat_V
    diff_mat!(diff_mat_V, V_vals, cone.V_vals_log)
    W_similar = cone.W_similar = V_vecs' * W * V_vecs
    temp = -V_vecs * (W_similar .* Hermitian(diff_mat_V, :U)) * V_vecs' / z
    dzdV = @views smat_to_svec!(cone.dzdV, temp, rt2)
    grad_V = temp - Vi
    @views smat_to_svec!(cone.grad[V_idxs], grad_V, rt2)

    cone.grad_updated = true
    return cone.grad
end

function update_hess(cone::EpiTraceRelEntropyTri{T}) where {T <: Real}
    @assert cone.is_feas
    d = cone.d
    rt2 = cone.rt2
    rteps = sqrt(eps(T))
    V_idxs = cone.V_idxs
    W_idxs = cone.W_idxs
    z = cone.z
    vw_dim = cone.vw_dim
    (V_vals, V_vecs) = cone.V_fact
    (W_vals, W_vecs) = cone.W_fact
    Vi = cone.Vi
    Wi = cone.Wi
    H = cone.hess.data

    diff_mat!(cone.diff_mat_W, W_vals, cone.W_vals_log)
    diff_mat_V = Hermitian(cone.diff_mat_V, :U)
    diff_mat_W = Hermitian(cone.diff_mat_W, :U)

    diff_tensor_V = zeros(T, d, d, d)
    diff_tensor!(diff_tensor_V, diff_mat_V, V_vals)

    W_similar = cone.W_similar
    dz_sqr_dV_sqr = zeros(T, vw_dim, vw_dim)
    hess_tr_logm!(dz_sqr_dV_sqr, V_vecs, W_similar, diff_tensor_V, cone.rt2)
    dzdV = cone.dzdV
    dz_dV_sqr = dzdV * dzdV'
    ViVi = symm_kron(zeros(T, vw_dim, vw_dim), Vi, rt2)
    Hvv = dz_dV_sqr - dz_sqr_dV_sqr / z + ViVi

    dz_sqr_dW_sqr = zeros(T, vw_dim, vw_dim)
    grad_logm!(dz_sqr_dW_sqr, W_vecs, cone.matsdim1, cone.matsdim2, cone.tempsdim, diff_mat_W, cone.rt2)
    dz_dW = cone.dzdW
    dz_dW_vec = smat_to_svec!(zeros(T, vw_dim), dz_dW, rt2)
    dz_dW_sqr = dz_dW_vec * dz_dW_vec'
    WiWi = symm_kron(zeros(T, vw_dim, vw_dim), Wi, rt2)
    Hww = dz_dW_sqr + dz_sqr_dW_sqr / z + WiWi

    dz_sqr_dW_dV = zeros(T, vw_dim, vw_dim)
    grad_logm!(dz_sqr_dW_dV, V_vecs, cone.matsdim1, cone.matsdim2, cone.tempsdim, diff_mat_V, cone.rt2)
    dz_dW_dz_dV = dz_dW_vec * dzdV'
    Hwv = -dz_sqr_dW_dV / z - dz_dW_dz_dV

    H[1, 1] = -cone.grad[1]
    @views H[1, V_idxs] .= -dzdV
    @views H[1, W_idxs] .= dz_dW_vec
    @views H[1, :] ./= z
    @views H[V_idxs, V_idxs] .= Hvv
    @views H[V_idxs, W_idxs] .= Hwv'
    @views H[W_idxs, W_idxs] .= Hww

    cone.hess_updated = true
    return cone.hess
end

function hess_tr_logm!(mat, vecs, mat_inner, diff_tensor, rt2::T) where T
    d = size(vecs, 1)
    X = zeros(T, d, d, d)
    for i in 1:d
        X[i, :, :] = vecs * (diff_tensor[i, :, :] .* mat_inner) * vecs'
    end
    temp = Symmetric(zeros(T, d^2, d^2), :U)
    for j in 1:d, i in 1:j
        temp.data[block_idxs(d, i), block_idxs(d, j)] = vecs * Diagonal(X[:, i, j]) * vecs'
    end

    row_idx = 1
    for j in 1:d, i in 1:j
        col_idx = 1
        for l in 1:d, k in 1:l
            mat[row_idx, col_idx] +=
                (
                temp[block_idxs(d, j), block_idxs(d, l)][i, k] +
                temp[block_idxs(d, i), block_idxs(d, l)][j, k] +
                temp[block_idxs(d, j), block_idxs(d, k)][i, l] +
                temp[block_idxs(d, i), block_idxs(d, k)][j, l]
                ) * (i == j ? 1 : rt2) * (k == l ? 1 : rt2)
            col_idx += 1
        end
        row_idx += 1
    end
    mat ./= 2

    return mat
end
