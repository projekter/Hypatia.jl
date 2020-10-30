#=
interpolation-based weighted-sum-of-squares (multivariate) polynomial epinormeucl (AKA second-order cone) parametrized by interpolation matrices Ps
certifies that u(x)^2 <= sum(w_i(x)^2) for all x in the domain described by input Ps
u(x), w_1(x), ...,  w_R(x) are polynomials with U coefficients

dual barrier extended from "Sum-of-squares optimization without semidefinite programming" by D. Papp and S. Yildiz, available at https://arxiv.org/abs/1712.01792
and "Semidefinite Characterization of Sum-of-Squares Cones in Algebras" by D. Papp and F. Alizadeh
-logdet(schur(Lambda)) - logdet(Lambda_11)
note that if schur(M) = A - B * inv(D) * C then
logdet(schur) = logdet(M) - logdet(D) = logdet(Lambda) - (R - 1) * logdet(Lambda_11)
since our D is an (R - 1) x (R - 1) block diagonal matrix
=#

mutable struct WSOSInterpEpiNormEucl{T <: Real} <: Cone{T}
    use_dual_barrier::Bool
    use_heuristic_neighborhood::Bool
    dim::Int
    R::Int
    U::Int
    Ps::Vector{Matrix{T}}

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

    mat::Vector{Matrix{T}}
    matfact::Vector
    Λi_Λ::Vector{Vector{Matrix{T}}}
    Λ11::Vector{Matrix{T}}
    tmpLL::Vector{Matrix{T}}
    tmpLU::Vector{Matrix{T}}
    tmpLU2::Vector{Matrix{T}}
    tmpUU_vec::Vector{Matrix{T}} # reused in update_hess
    tmpUU::Matrix{T}
    PΛiPs::Vector{Vector{Vector{Matrix{T}}}}
    Λ11iP::Vector{Matrix{T}}
    PΛ11iP::Vector{Matrix{T}}
    lambdafact::Vector
    point_views

    function WSOSInterpEpiNormEucl{T}(
        R::Int,
        U::Int,
        Ps::Vector{Matrix{T}};
        use_dual::Bool = false,
        use_heuristic_neighborhood::Bool = default_use_heuristic_neighborhood(),
        hess_fact_cache = hessian_cache(T),
        ) where {T <: Real}
        for Pj in Ps
            @assert size(Pj, 1) == U
        end
        cone = new{T}()
        cone.use_dual_barrier = !use_dual # using dual barrier
        cone.use_heuristic_neighborhood = use_heuristic_neighborhood
        cone.dim = U * R
        cone.R = R
        cone.U = U
        cone.Ps = Ps
        cone.hess_fact_cache = hess_fact_cache
        return cone
    end
end

function setup_extra_data(cone::WSOSInterpEpiNormEucl{T}) where {T <: Real}
    dim = cone.dim
    U = cone.U
    R = cone.R
    Ps = cone.Ps
    cone.hess = Symmetric(zeros(T, dim, dim), :U)
    cone.inv_hess = Symmetric(zeros(T, dim, dim), :U)
    load_matrix(cone.hess_fact_cache, cone.hess)
    cone.mat = [zeros(T, size(Psk, 2), size(Psk, 2)) for Psk in Ps]
    cone.matfact = Vector{Any}(undef, length(Ps))
    cone.Λi_Λ = [Vector{Matrix{T}}(undef, R - 1) for Psk in Ps]
    @inbounds for k in eachindex(Ps), r in 1:(R - 1)
        cone.Λi_Λ[k][r] = zeros(T, size(Ps[k], 2), size(Ps[k], 2))
    end
    cone.Λ11 = [zeros(T, size(Psk, 2), size(Psk, 2)) for Psk in Ps]
    cone.tmpLL = [zeros(T, size(Psk, 2), size(Psk, 2)) for Psk in Ps]
    cone.tmpLU = [zeros(T, size(Psk, 2), U) for Psk in Ps]
    cone.tmpLU2 = [zeros(T, size(Psk, 2), U) for Psk in Ps]
    cone.tmpUU_vec = [zeros(T, U, U) for _ in eachindex(Ps)]
    cone.tmpUU = zeros(T, U, U)
    cone.PΛiPs = [Vector{Vector{Matrix{T}}}(undef, R) for Psk in Ps]
    @inbounds for k in eachindex(Ps), r1 in 1:R
        cone.PΛiPs[k][r1] = Vector{Matrix{T}}(undef, r1)
        for r2 in 1:r1
            cone.PΛiPs[k][r1][r2] = zeros(T, U, U)
        end
    end
    cone.Λ11iP = [zeros(T, size(P, 2), U) for P in Ps]
    cone.PΛ11iP = [zeros(T, U, U) for _ in eachindex(Ps)]
    cone.lambdafact = Vector{Any}(undef, length(Ps))
    cone.point_views = [view(cone.point, block_idxs(U, i)) for i in 1:R]
    return cone
end

get_nu(cone::WSOSInterpEpiNormEucl) = 2 * sum(size(Psk, 2) for Psk in cone.Ps)

use_correction(::WSOSInterpEpiNormEucl) = false

function set_initial_point(arr::AbstractVector, cone::WSOSInterpEpiNormEucl)
    @views arr[1:cone.U] .= 1
    @views arr[(cone.U + 1):end] .= 0
    return arr
end

function update_feas(cone::WSOSInterpEpiNormEucl)
    @assert !cone.feas_updated
    U = cone.U
    lambdafact = cone.lambdafact
    matfact = cone.matfact
    point_views = cone.point_views

    cone.is_feas = true
    @inbounds for k in eachindex(cone.Ps)
        Psk = cone.Ps[k]
        Λ11j = cone.Λ11[k]
        LLk = cone.tmpLL[k]
        LUk = cone.tmpLU[k]
        Λi_Λ = cone.Λi_Λ[k]
        mat = cone.mat[k]

        # first lambda
        @. LUk = Psk' * point_views[1]'
        mul!(Λ11j, LUk, Psk)
        copyto!(mat, Λ11j)
        lambdafact[k] = cholesky!(Symmetric(Λ11j, :U), check = false)
        if !isposdef(lambdafact[k])
            cone.is_feas = false
            break
        end

        # subtract others
        uo = U + 1
        @inbounds for r in 2:cone.R
            @. LUk = Psk' * point_views[r]'
            mul!(LLk, LUk, Psk)

            # not using lambdafact.L \ lambda with an syrk because storing lambdafact \ lambda is useful later
            ldiv!(Λi_Λ[r - 1], lambdafact[k], LLk)
            mul!(mat, LLk, Λi_Λ[r - 1], -1, true)
            uo += U
        end

        matfact[k] = cholesky!(Symmetric(mat, :U), check = false)
        if !isposdef(matfact[k])
            cone.is_feas = false
            break
        end
    end

    cone.feas_updated = true
    return cone.is_feas
end

is_dual_feas(cone::WSOSInterpEpiNormEucl) = true

function update_grad(cone::WSOSInterpEpiNormEucl{T}) where T
    @assert cone.is_feas
    U = cone.U
    R = cone.R
    R2 = R - 2
    lambdafact = cone.lambdafact
    matfact = cone.matfact

    cone.grad .= 0
    @inbounds for k in eachindex(cone.Ps)
        Psk = cone.Ps[k]
        Λ11iP = cone.Λ11iP[k]
        LUk = cone.tmpLU[k]
        LUk2 = cone.tmpLU2[k]
        PΛ11iP = cone.PΛ11iP[k]
        PΛiPs = cone.PΛiPs[k]
        Λi_Λ = cone.Λi_Λ[k]

        # P * inv(Λ_11) * P' for (1, 1) hessian block and adding to PΛiPs[r][r]
        ldiv!(Λ11iP, cone.lambdafact[k].L, Psk') # TODO may be more efficient to do ldiv(fact.U', B) than ldiv(fact.L, B) here and elsewhere since the factorizations are of symmetric :U matrices
        mul!(PΛ11iP, Λ11iP', Λ11iP)

        # prep PΛiPs
        # block-(1,1) is P * inv(mat) * P'
        ldiv!(LUk, matfact[k].L, Psk')
        mul!(PΛiPs[1][1], LUk', LUk)
        # get all the PΛiPs that are in row one or on the diagonal
        @inbounds for r in 2:R
            ldiv!(LUk, matfact[k], Psk')
            mul!(LUk2, Λi_Λ[r - 1], LUk)
            mul!(PΛiPs[r][1], Psk, LUk2, -1, false)
            # PΛiPs[r][r] .= Symmetric(Psk * Λi_Λ[r - 1] * (matfact[k] \ (Λi_Λ[r - 1]' * Psk')), :U)
            mul!(LUk, Λi_Λ[r - 1]', Psk')
            ldiv!(matfact[k].L, LUk)
            mul!(PΛiPs[r][r], LUk', LUk)
            @. PΛiPs[r][r] += PΛ11iP
        end

        # (1, 1)-block
        # gradient is diag of sum(-PΛiPs[i][i] for i in 1:R) + (R - 1) * P((Lambda_11)\P') - P((Lambda_11)\P')
        @inbounds for i in 1:U
            cone.grad[i] += PΛ11iP[i, i] * R2
            @inbounds for r in 1:R
                cone.grad[i] -= PΛiPs[r][r][i, i]
            end
        end
        idx = U + 1
        @inbounds for r in 2:R, i in 1:U
            cone.grad[idx] -= 2 * PΛiPs[r][1][i, i]
            idx += 1
        end
    end

    cone.grad_updated = true
    return cone.grad
end

function update_hess(cone::WSOSInterpEpiNormEucl)
    @assert cone.grad_updated
    U = cone.U
    R = cone.R
    R2 = R - 2
    hess = cone.hess.data
    UU = cone.tmpUU
    matfact = cone.matfact

    hess .= 0
    @inbounds for k in eachindex(cone.Ps)
        Psk = cone.Ps[k]
        PΛiPs = cone.PΛiPs[k]
        Λi_Λ = cone.Λi_Λ[k]
        PΛ11iP = cone.PΛ11iP[k]
        UUk = cone.tmpUU_vec[k]
        LUk = cone.tmpLU[k]
        LUk2 = cone.tmpLU2[k]

        # get the PΛiPs not calculated in update_grad
        @inbounds for r in 2:R, r2 in 2:(r - 1)
            mul!(LUk, Λi_Λ[r2 - 1]', Psk')
            ldiv!(matfact[k], LUk)
            mul!(LUk2, Λi_Λ[r - 1], LUk)
            mul!(PΛiPs[r][r2], Psk, LUk2)
        end

        @inbounds for i in 1:U, k in 1:i
            hess[k, i] -= abs2(PΛ11iP[k, i]) * R2
        end

        @. @views hess[1:U, 1:U] += abs2(PΛiPs[1][1])
        @inbounds for r in 2:R
            idxs = block_idxs(U, r)
            @inbounds for s in 1:(r - 1)
                # block (1,1)
                @. UU = abs2(PΛiPs[r][s])
                @. UUk = UU + UU'
                @. @views hess[1:U, 1:U] += UUk
                # blocks (1,r)
                @. @views hess[1:U, idxs] += PΛiPs[s][1] * PΛiPs[r][s]'
            end
            # block (1,1)
            @. @views hess[1:U, 1:U] += abs2(PΛiPs[r][r])
            # blocks (1,r)
            @. @views hess[1:U, idxs] += PΛiPs[r][1] * PΛiPs[r][r]
            # blocks (1,r)
            @inbounds for s in (r + 1):R
                @. @views hess[1:U, idxs] += PΛiPs[s][1] * PΛiPs[s][r]
            end

            # blocks (r, r2)
            # NOTE for hess[idxs, idxs], UU and UUk are symmetric
            @. UU = PΛiPs[r][1] * PΛiPs[r][1]'
            @. UUk = PΛiPs[1][1] * PΛiPs[r][r]
            @. @views hess[idxs, idxs] += UU + UUk
            @inbounds for r2 in (r + 1):R
                @. UU = PΛiPs[r][1] * PΛiPs[r2][1]'
                @. UUk = PΛiPs[1][1] * PΛiPs[r2][r]'
                idxs2 = block_idxs(U, r2)
                @. @views hess[idxs, idxs2] += UU + UUk
            end
        end
    end
    @. @views hess[:, (U + 1):cone.dim] *= 2

    cone.hess_updated = true
    return cone.hess
end

# TODO allocations, inbounds etc
function correction(cone::WSOSInterpEpiNormEucl{T}, primal_dir::AbstractVector{T}) where T
    corr = cone.correction
    corr .= 0
    R = cone.R
    U = cone.U
    UR = U * R
    @views primal_dir_1 = Diagonal(primal_dir[1:U])
    dim = cone.dim

    for pk in eachindex(cone.Ps)
        PlambdaPk = cone.PΛiPs[pk]
        PΛP(i, j) = (j <= i ? PlambdaPk[i][j] : PlambdaPk[j][i]')
        PΛ11iP = cone.PΛ11iP[pk]

        PΛP_dirs_pqq = [zeros(T, U, U) for _ in 1:R, _ in 1:R]
        PΛP_dirs_pq1 = [zeros(T, U, U) for _ in 1:R, _ in 1:R]
        PΛP_dirs_p1q = [zeros(T, U, U) for _ in 1:R, _ in 1:R]
        @views for p in 1:R, q in 1:R
            PΛP_dirs_pqq[p, q] = PΛP(p, q) * Diagonal(primal_dir[block_idxs(U, q)])
            PΛP_dirs_pq1[p, q] = PΛP(p, q) * Diagonal(primal_dir[1:U])
            PΛP_dirs_p1q[p, q] = PΛP(p, 1) * Diagonal(primal_dir[block_idxs(U, q)])
        end
        @views LU = cone.Λ11iP[pk] * Diagonal(primal_dir[1:U]) * PΛ11iP

        # 111
        for j in 1:U
            @views corr[j] -= sum(abs2, LU[:, j]) * (R - 2)
        end
        M = sum(PΛP_dirs_pq1[i, k] * PΛP_dirs_pq1[k, m] * PΛP(m, i) for i in 1:R for k in 1:R for m in 1:R)
        @views corr[1:U] .+= diag(M)

        # 11m
        @inbounds for m in 2:R
            M = sum(
                PΛP_dirs_pq1[i, k] * (PΛP_dirs_pqq[k, m] * PΛP(1, i) + PΛP(k, 1) * PΛP_dirs_pqq[i, m]')
                for i in 1:R, k in 1:R)
            @views corr[1:U] .+= diag(M) * 2
        end

        # 1km
        for k in 2:R, m in 2:R
            M = sum(
                PΛP_dirs_pqq[i, k] * (PΛP_dirs_p1q[1, m] * PΛP(m, i) + PΛP_dirs_pqq[1, m] * PΛP(1, i)) +
                PΛP_dirs_p1q[i, k] * (PΛP_dirs_p1q[k, m] * PΛP(m, i) + PΛP_dirs_pqq[k, m] * PΛP(1, i))
                for i in 1:R)
            @views corr[1:U] .+= diag(M)
        end

        for i in 2:R
            # 11i
            M = sum(PΛP_dirs_pq1[i, m] * PΛP_dirs_pq1[m, k] * PΛP(k, 1) + PΛP_dirs_pq1[1, m] * PΛP_dirs_pq1[m, k] * PΛP(k, i)
                for k in 1:R for m in 1:R)
            @views corr[block_idxs(U, i)] .+= diag(M)

            # im1
            for m in 2:R
                M = sum(
                    PΛP_dirs_pq1[i, k] * (PΛP_dirs_pqq[k, m] * PΛP(1, 1) + PΛP_dirs_p1q[k, m] * PΛP(m, 1)) +
                    PΛP_dirs_pq1[1, k] * (PΛP_dirs_pqq[k, m] * PΛP(1, i) + PΛP_dirs_p1q[k, m] * PΛP(m, i))
                    for k in 1:R)
                @views corr[block_idxs(U, i)] .+= diag(M) * 2
            end

            # ikm
            for k in 2:R, m in 2:R
                M = PΛP_dirs_p1q[i, k] * PΛP_dirs_p1q[k, m] * PΛP(1, m)' +
                    PΛP_dirs_p1q[1, k] * PΛP_dirs_p1q[k, m] * PΛP(i, m)' +
                    PΛP_dirs_pqq[i, k] * PΛP_dirs_p1q[1, m] * PΛP(1, m)' +
                    PΛP_dirs_pqq[1, k] * PΛP_dirs_p1q[1, m] * PΛP(i, m)' +
                    PΛP_dirs_p1q[i, k] * PΛP_dirs_pqq[k, m] * PΛP(1, 1)' +
                    PΛP_dirs_p1q[1, k] * PΛP_dirs_pqq[k, m] * PΛP(i, 1)' +
                    PΛP_dirs_pqq[i, k] * PΛP_dirs_pqq[1, m] * PΛP(1, 1)' +
                    PΛP_dirs_pqq[1, k] * PΛP_dirs_pqq[1, m] * PΛP(i, 1)'
                @views corr[block_idxs(U, i)] .+= diag(M)
            end
        end
    end

    return corr
end
