"""
$(TYPEDEF)

Real symmetric or complex Hermitian positive semidefinite cone of squares.
"""
struct MatrixCSqr{T <: Real, R <: RealOrComplex{T}} <: ConeOfSquares{T} end

"""
$(TYPEDSIGNATURES)

The rank of the matrix cone of squares, equal to the side dimension of the matrix.
"""
vector_dim(::Type{<:MatrixCSqr{<:Real, R}}, d::Int) where R = svec_length(R, d)

mutable struct MatrixCSqrCache{T <: Real, R <: RealOrComplex{T}} <: CSqrCache{T}
    is_complex::Bool
    rt2::T
    viw_X::Matrix{R}
    viw_λ::Vector{T}
    w_λ::Vector{T}
    w_λi::Vector{T}
    ϕ::T
    ζ::T
    ζi::T
    ζivi::T
    σ::T
    ∇h::Vector{T}
    ∇2h::Vector{T}
    ∇3h::Vector{T}
    viw_λ_Δ::Vector{T}
    Δh::Matrix{T}
    Δ2h::Matrix{T}
    θ::Matrix{T}

    α::Vector{T}
    γ::Vector{T}
    k1::T
    k2::T
    k3::T

    wd::Vector{T}
    wT::Matrix{T}
    w1::Matrix{R}
    w2::Matrix{R}
    w3::Matrix{R}
    w4::Matrix{R}

    MatrixCSqrCache{T, R}() where {T <: Real, R <: RealOrComplex{T}} = new{T, R}()
end

function setup_csqr_cache(cone::EpiPerSepSpectral{MatrixCSqr{T, R}}) where {T, R}
    cone.cache = cache = MatrixCSqrCache{T, R}()
    cache.is_complex = (R <: Complex{T})
    cache.rt2 = sqrt(T(2))
    d = cone.d
    cache.viw_X = zeros(R, d, d)
    cache.w_λ = zeros(T, d)
    cache.w_λi = zeros(T, d)
    cache.∇h = zeros(T, d)
    cache.∇2h = zeros(T, d)
    cache.∇3h = zeros(T, d)
    cache.viw_λ_Δ = zeros(T, svec_length(d))
    cache.Δh = zeros(T, d, d)
    cache.Δ2h = zeros(T, d, svec_length(d))
    cache.θ = zeros(T, d, d)
    cache.wd = zeros(T, d)
    cache.wT = zeros(T, d, d)
    cache.w1 = zeros(R, d, d)
    cache.w2 = zeros(R, d, d)
    cache.w3 = zeros(R, d, d)
    cache.w4 = zeros(R, d, d)
    cache.α = zeros(T, d)
    cache.γ = zeros(T, d)
    return
end

function set_initial_point!(
    arr::AbstractVector,
    cone::EpiPerSepSpectral{<:MatrixCSqr},
    )
    (arr[1], arr[2], w0) = get_initial_point(cone.d, cone.h)
    @views fill!(arr[3:end], 0)
    incr = (cone.cache.is_complex ? 2 : 1)
    idx = 3
    @inbounds for i in 1:cone.d
        arr[idx] = 1
        idx += incr * i + 1
    end
    return arr
end

function update_feas(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    @assert !cone.feas_updated
    cache = cone.cache
    v = cone.point[2]

    cone.is_feas = false
    if v > eps(T)
        w = viw_X = cache.viw_X
        # try cholesky before eigdecomp
        svec_to_smat!(w, cone.w_view, cache.rt2)
        w_chol = cholesky!(Hermitian(w, :U), check = false)
        if isposdef(w_chol)
            svec_to_smat!(w, cone.w_view, cache.rt2)
            w ./= v
            viw_λ = cache.viw_λ = update_eigen!(viw_X)
            if all(>(eps(T)), viw_λ)
                cache.ϕ = h_val(viw_λ, cone.h)
                cache.ζ = cone.point[1] - v * cache.ϕ
                cone.is_feas = (cache.ζ > eps(T))
            end
        end
    end

    cone.feas_updated = true
    return cone.is_feas
end

function is_dual_feas(cone::EpiPerSepSpectral{MatrixCSqr{T, R}}) where {T, R}
    u = cone.dual_point[1]
    (u < eps(T)) && return false
    @views w = cone.dual_point[3:end]

    uiw = cone.cache.w1
    if h_conj_dom_pos(cone.h)
        # use cholesky to check conjugate domain feasibility
        svec_to_smat!(uiw, w, cone.cache.rt2)
        w_chol = cholesky!(Hermitian(uiw, :U), check = false)
        isposdef(w_chol) || return false
    end

    svec_to_smat!(uiw, w, cone.cache.rt2)
    uiw ./= u
    uiw_λ = eigvals!(Hermitian(uiw, :U))
    return (cone.dual_point[2] - u * h_conj(uiw_λ, cone.h) > eps(T))
end

function update_grad(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    @assert !cone.grad_updated && cone.is_feas
    v = cone.point[2]
    grad = cone.grad
    cache = cone.cache
    ζi = cache.ζi = inv(cache.ζ)
    viw_λ = cache.viw_λ
    viw_X = cache.viw_X
    ∇h = cache.∇h
    h_der1(∇h, viw_λ, cone.h)
    cache.σ = cache.ϕ - dot(viw_λ, ∇h)
    @. cache.w_λ = v * viw_λ
    @. cache.w_λi = inv(cache.w_λ)

    grad[1] = -ζi
    grad[2] = -inv(v) + ζi * cache.σ
    @. cache.wd = ζi * ∇h - cache.w_λi
    mul!(cache.w1, viw_X, Diagonal(cache.wd))
    gw = mul!(cache.w2, cache.w1, viw_X')
    @views smat_to_svec!(cone.grad[3:end], gw, cache.rt2)

    cone.grad_updated = true
    return grad
end

function update_hess_aux(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    @assert !cone.hess_aux_updated
    @assert cone.grad_updated
    cache = cone.cache
    viw_λ = cache.viw_λ
    w_λi = cache.w_λi
    ∇h = cache.∇h
    ∇2h = cache.∇2h
    viw_λ_Δ = cache.viw_λ_Δ
    Δh = cache.Δh

    cache.ζivi = inv(cache.ζ * cone.point[2])
    h_der2(∇2h, viw_λ, cone.h)

    # setup viw_λ_Δ
    rteps = sqrt(eps(T))
    idx = 1
    @inbounds for j in 1:cone.d
        λ_j = viw_λ[j]
        for i in 1:(j - 1)
            t = viw_λ[i] - λ_j
            if abs(t) < rteps
                viw_λ_Δ[idx] = 0
            else
                viw_λ_Δ[idx] = t
            end
            idx += 1
        end
        viw_λ_Δ[idx] = 0
        idx += 1
    end

    # setup Δh
    idx = 1
    @inbounds for j in 1:cone.d
        ∇h_j = ∇h[j]
        Δh[j, j] = ∇2h_j = ∇2h[j]
        for i in 1:(j - 1)
            denom = viw_λ_Δ[idx]
            if iszero(denom)
                Δh[i, j] = (∇2h[i] + ∇2h_j) / 2
            else
                Δh[i, j] = (∇h[i] - ∇h_j) / denom
            end
            idx += 1
        end
        idx += 1
    end

    ζivi = cache.ζi / cone.point[2]
    @. cache.θ = ζivi * Δh + w_λi * w_λi'
    copytri!(cache.θ, 'U')

    cone.hess_aux_updated = true
end

function update_hess(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    cone.hess_aux_updated || update_hess_aux(cone)
    isdefined(cone, :hess) || alloc_hess!(cone)
    d = cone.d
    v = cone.point[2]
    H = cone.hess.data
    cache = cone.cache
    rt2 = cache.rt2
    ζi = cache.ζi
    ζivi = cache.ζivi
    σ = cache.σ
    viw_X = cache.viw_X
    viw_λ = cache.viw_λ
    ∇h = cache.∇h
    ∇2h = cache.∇2h
    wd = cache.wd
    w1 = cache.w1
    w2 = cache.w2
    ζi2 = abs2(ζi)

    # Huu
    H[1, 1] = ζi2

    # Huv
    H[1, 2] = -ζi2 * σ

    # Hvv
    @inbounds sum1 = sum(abs2(viw_λ[j]) * ∇2h[j] for j in 1:d)
    H[2, 2] = v^-2 + abs2(ζi * σ) + ζivi * sum1

    # Huw
    @. wd = -ζi * ∇h
    mul!(w1, Diagonal(wd), viw_X')
    mul!(w2, viw_X, w1)
    @views Hwu = H[3:end, 1] # use later for Hww
    @views smat_to_svec!(Hwu, w2, rt2)
    @. H[1, 3:end] = ζi * Hwu

    # Hvw
    wd .*= -ζi * σ
    @. wd -= ζivi * ∇2h * viw_λ
    mul!(w1, Diagonal(wd), viw_X')
    mul!(w2, viw_X, w1)
    @views smat_to_svec!(H[2, 3:end], w2, rt2)

    # Hww
    @views Hww = H[3:end, 3:end]
    eig_dot_kron!(Hww, cache.θ, viw_X, w1, w2, cache.w3, rt2)
    mul!(Hww, Hwu, Hwu', true, true)

    cone.hess_updated = true
    return cone.hess
end

function hess_prod!(
    prod::AbstractVecOrMat{T},
    arr::AbstractVecOrMat{T},
    cone::EpiPerSepSpectral{<:MatrixCSqr{T}},
    ) where T
    cone.hess_aux_updated || update_hess_aux(cone)
    d = cone.d
    v = cone.point[2]
    cache = cone.cache
    ζi = cache.ζi
    ζivi = cache.ζivi
    σ = cache.σ
    viw_X = cache.viw_X
    viw_λ = cache.viw_λ
    w_λi = cache.w_λi
    ∇h = cache.∇h
    Δh = cache.Δh
    r_X = cache.w1
    w2 = cache.w2
    w3 = cache.w3
    D_λi = Diagonal(w_λi)
    D_viw_λ = Diagonal(viw_λ)
    D_∇h = Diagonal(∇h)

    @inbounds for j in 1:size(arr, 2)
        p = arr[1, j]
        q = arr[2, j]
        @views svec_to_smat!(r_X, arr[3:end, j], cache.rt2)
        mul!(w2, Hermitian(r_X, :U), viw_X)
        mul!(r_X, viw_X', w2)

        sum1 = sum(∇h[i] * real(r_X[i, i]) for i in 1:d)
        c1 = -ζi * (p - σ * q - sum1) * ζi
        @. w2 = ζivi * Δh * (r_X - q * D_viw_λ)
        c2 = sum(viw_λ[i] * real(w2[i, i]) for i in 1:d)

        rmul!(r_X, D_λi)
        @. w2 += w_λi * r_X + c1 * D_∇h
        mul!(w3, viw_X, Hermitian(w2, :U))
        mul!(w2, w3, viw_X')

        prod[1, j] = -c1
        prod[2, j] = c1 * σ - c2 + q / v / v
        @views smat_to_svec!(prod[3:end, j], w2, cache.rt2)
    end

    return prod
end

function update_inv_hess_aux(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    @assert !cone.inv_hess_aux_updated
    cone.hess_aux_updated || update_hess_aux(cone)
    v = cone.point[2]
    cache = cone.cache
    ∇h = cache.∇h
    wd = cache.wd
    α = cache.α
    γ = cache.γ

    @. wd = cache.ζivi * cache.∇2h
    @views diag_θ = cache.θ[1:(1 + cone.d):end]
    @. α = ∇h / diag_θ
    @. γ = cache.viw_λ / diag_θ * wd

    cache.k1 = abs2(cache.ζ) + dot(∇h, α)
    cache.k2 = cache.σ + dot(∇h, γ)
    cache.k3 = (inv(v) + dot(cache.w_λi, γ)) / v

    cone.inv_hess_aux_updated = true
end

function update_inv_hess(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    cone.inv_hess_aux_updated || update_inv_hess_aux(cone)
    isdefined(cone, :inv_hess) || alloc_inv_hess!(cone)
    Hi = cone.inv_hess.data
    cache = cone.cache
    rt2 = cache.rt2
    viw_X = cache.viw_X
    k2 = cache.k2
    k3 = cache.k3
    wT = cache.wT
    w1 = cache.w1
    w2 = cache.w2

    k23i = k2 / k3
    Hi[1, 1] = cache.k1 + k23i * k2
    Hi[1, 2] = k23i
    Hi[2, 2] = inv(k3)

    # Hiuw, Hivw
    @views HiuW = Hi[1, 3:end]
    @views γ_vec = Hi[3:end, 2]
    mul!(w2, Diagonal(cache.γ), viw_X')
    mul!(w1, viw_X, w2)
    smat_to_svec!(γ_vec, w1, rt2)
    @. Hi[2, 3:end] = γ_vec / k3
    mul!(w2, Diagonal(cache.α), viw_X')
    mul!(w1, viw_X, w2)
    smat_to_svec!(HiuW, w1, rt2)
    @. HiuW += k23i * γ_vec

    # Hiww
    @views Hiww = Hi[3:end, 3:end]
    @. wT = inv(cache.θ)
    eig_dot_kron!(Hiww, wT, viw_X, w1, w2, cache.w3, rt2)
    mul!(Hiww, γ_vec, γ_vec', inv(k3), true)

    cone.inv_hess_updated = true
    return cone.inv_hess
end

function inv_hess_prod!(
    prod::AbstractVecOrMat{T},
    arr::AbstractVecOrMat{T},
    cone::EpiPerSepSpectral{<:MatrixCSqr{T}},
    ) where T
    cone.inv_hess_aux_updated || update_inv_hess_aux(cone)
    d = cone.d
    cache = cone.cache
    viw_X = cache.viw_X
    α = cache.α
    γ = cache.γ
    k1 = cache.k1
    k2 = cache.k2
    k3 = cache.k3
    r_X = cache.w1
    w2 = cache.w2

    @inbounds for j in 1:size(arr, 2)
        p = arr[1, j]
        @views svec_to_smat!(r_X, arr[3:end, j], cache.rt2)
        mul!(w2, Hermitian(r_X, :U), viw_X)
        mul!(r_X, viw_X', w2)

        cv = (k2 * p + arr[2, j] + sum(γ[i] * real(r_X[i, i]) for i in 1:d)) / k3

        prod[1, j] = k1 * p + k2 * cv + sum(α[i] * real(r_X[i, i]) for i in 1:d)
        prod[2, j] = cv

        r_X ./= cache.θ
        for i in 1:d
            r_X[i, i] += p * α[i] + cv * γ[i]
        end
        mul!(w2, viw_X, Hermitian(r_X, :U))
        mul!(r_X, w2, viw_X')
        @views smat_to_svec!(prod[3:end, j], r_X, cache.rt2)
    end

    return prod
end

function update_dder3_aux(cone::EpiPerSepSpectral{<:MatrixCSqr{T}}) where T
    @assert !cone.dder3_aux_updated
    cone.hess_aux_updated || update_hess_aux(cone)
    d = cone.d
    cache = cone.cache
    viw_λ = cache.viw_λ
    ∇3h = cache.∇3h
    viw_λ_Δ = cache.viw_λ_Δ
    Δh = cache.Δh
    Δ2h = cache.Δ2h

    h_der3(∇3h, viw_λ, cone.h)

    # setup Δ2h
    i6 = inv(T(6))
    @inbounds Threads.@threads for k in 1:d
        idx_jk = sum(1:(k - 1))
        ∇3h_k = ∇3h[k]
        idx_ij = 1
        kd = d * (k - 1)
        for j in 1:k
            ∇3h_jk = ∇3h[j] + ∇3h_k
            Δh_jk = Δh[j, k]
            ijk = d * (idx_jk - 1 + j)
            jik = d * idx_jk + j
            kij = d * (idx_ij - 1) + k
            jd = d * (j - 1)

            @inbounds for i in 1:j
                denom_ij = viw_λ_Δ[idx_ij]
                Δ2h[ijk + i] = Δ2h[jik] = Δ2h[kij] = begin
                    if iszero(denom_ij)
                        denom_ik = viw_λ_Δ[idx_jk + i]
                        if iszero(denom_ik)
                            (∇3h[i] + ∇3h_jk) * i6
                        else
                            (Δh[jd + i] - Δh_jk) / denom_ik
                        end
                    else
                        (Δh[kd + i] - Δh_jk) / denom_ij
                    end
                end

                idx_ij += 1
                jik += d
                kij += d
            end
        end
    end

    cone.dder3_aux_updated = true
    return
end

function dder3(
    cone::EpiPerSepSpectral{<:MatrixCSqr{T}},
    dir::AbstractVector{T},
    ) where T
    cone.dder3_aux_updated || update_dder3_aux(cone)
    d = cone.d
    v = cone.point[2]
    dder3 = cone.dder3
    cache = cone.cache
    ζi = cache.ζi
    viw_X = cache.viw_X
    viw_λ = cache.viw_λ
    w_λi = cache.w_λi
    σ = cache.σ
    ∇h = cache.∇h
    ∇2h = cache.∇2h
    Δ2h = cache.Δ2h
    r_X = cache.w1
    ξ_X = cache.w2
    ξb = cache.w3
    w4 = cache.w4
    wd = cache.wd

    p = dir[1]
    q = dir[2]
    @views svec_to_smat!(r_X, dir[3:end], cache.rt2)
    mul!(ξ_X, Hermitian(r_X, :U), viw_X)
    mul!(r_X, viw_X', ξ_X)
    LinearAlgebra.copytri!(r_X, 'U', true)

    viq = q / v
    D = Diagonal(viw_λ)
    @. ξ_X = (r_X - q * D) / v
    @. ξb = ζi * cache.Δh * ξ_X
    @inbounds sum1 = sum(∇h[i] * real(r_X[i, i]) for i in 1:d)
    ζiχ = ζi * (p - σ * q - sum1)
    ξbξ = dot(Hermitian(ξb, :U), Hermitian(ξ_X, :U)) / 2
    c1 = -ζi * (ζiχ^2 + v * ξbξ)

    w_aux = ξb
    lmul!(ζiχ + viq, w_aux)
    col = 1
    @inbounds for j in 1:d
        @views @. w4[:, 1:j] = ξ_X[:, 1:j] * Δ2h[:, col:(col + j - 1)]
        @views mul!(w_aux[1:j, j], w4[:, 1:j]', ξ_X[:, j], -ζi, true)
        col += j
    end
    @inbounds c2 = sum(viw_λ[i] * real(w_aux[i, i]) for i in 1:d)

    @. wd = sqrt(w_λi)
    lmul!(Diagonal(w_λi), r_X)
    rmul!(r_X, Diagonal(wd))
    mul!(w_aux, r_X, r_X', true, true)
    D_∇h = Diagonal(∇h)
    @. w_aux += c1 * D_∇h
    mul!(ξ_X, viw_X, Hermitian(w_aux, :U))
    mul!(w_aux, ξ_X, viw_X')

    dder3[1] = -c1
    @inbounds dder3[2] = c1 * σ - c2 + ξbξ + viq^2 / v
    @views smat_to_svec!(dder3[3:end], w_aux, cache.rt2)

    return dder3
end
