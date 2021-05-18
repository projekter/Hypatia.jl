"""
$(TYPEDEF)

Hypograph of geometric mean cone of dimension `dim`.

    $(FUNCTIONNAME){T}(dim::Int, use_dual::Bool = false)
"""
mutable struct HypoGeoMean{T <: Real} <: Cone{T}
    use_dual_barrier::Bool
    dim::Int

    point::Vector{T}
    dual_point::Vector{T}
    grad::Vector{T}
    dder3::Vector{T}
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

    iw_dim::T
    wgeo::T
    z::T
    tempw::Vector{T}

    function HypoGeoMean{T}(
        dim::Int;
        use_dual::Bool = false,
        hess_fact_cache = hessian_cache(T),
        ) where {T <: Real}
        @assert dim >= 2
        cone = new{T}()
        cone.use_dual_barrier = use_dual
        cone.dim = dim
        cone.hess_fact_cache = hess_fact_cache
        return cone
    end
end

function setup_extra_data!(cone::HypoGeoMean{T}) where {T <: Real}
    w_dim = cone.dim - 1
    cone.tempw = zeros(T, w_dim)
    cone.iw_dim = inv(T(w_dim))
    return cone
end

get_nu(cone::HypoGeoMean) = cone.dim

function set_initial_point!(arr::AbstractVector{T}, cone::HypoGeoMean{T}) where T
    w_dim = cone.dim - 1
    c = sqrt(T(5 * w_dim ^ 2 + 2 * w_dim + 1))
    arr[1] = -sqrt((-c + 3 * w_dim + 1) / T(2 * cone.dim))
    @views arr[2:end] .= (c - w_dim + 1) / sqrt(cone.dim * (-2 * c + 6 * w_dim + 2))
    return arr
end

function update_feas(cone::HypoGeoMean{T}) where T
    @assert !cone.feas_updated
    u = cone.point[1]
    @views w = cone.point[2:end]

    if all(>(eps(T)), w)
        cone.wgeo = exp(cone.iw_dim * sum(log, w))
        cone.z = cone.wgeo - u
        cone.is_feas = (cone.z > eps(T))
    else
        cone.is_feas = false
    end

    cone.feas_updated = true
    return cone.is_feas
end

function is_dual_feas(cone::HypoGeoMean{T}) where T
    u = cone.dual_point[1]
    @views w = cone.dual_point[2:end]

    if u < -eps(T) && all(>(eps(T)), w)
        return ((cone.dim - 1) * exp(cone.iw_dim * sum(log, w)) + u > eps(T))
    end

    return false
end

function update_grad(cone::HypoGeoMean)
    @assert cone.is_feas
    u = cone.point[1]
    @views w = cone.point[2:end]

    cone.grad[1] = inv(cone.z)
    gconst = -cone.iw_dim * cone.wgeo / cone.z - 1
    @. @views cone.grad[2:end] = gconst / w

    cone.grad_updated = true
    return cone.grad
end

function update_hess(cone::HypoGeoMean)
    @assert cone.grad_updated
    isdefined(cone, :hess) || alloc_hess!(cone)
    H = cone.hess.data
    u = cone.point[1]
    @views w = cone.point[2:end]
    z = cone.z
    iw_dim = cone.iw_dim
    wgeoz = iw_dim * cone.wgeo / z
    wgeozm1 = wgeoz - iw_dim
    constww = wgeoz * (1 + wgeozm1) + 1

    H[1, 1] = abs2(cone.grad[1])
    @inbounds for j in eachindex(w)
        j1 = j + 1
        wj = w[j]
        wgeozwj = wgeoz / wj
        H[1, j1] = -wgeozwj / z
        wgeozwj2 = wgeozwj * wgeozm1
        @inbounds for i in 1:(j - 1)
            H[i + 1, j1] = wgeozwj2 / w[i]
        end
        H[j1, j1] = constww / wj / wj
    end

    cone.hess_updated = true
    return cone.hess
end

function hess_prod!(
    prod::AbstractVecOrMat{T},
    arr::AbstractVecOrMat{T},
    cone::HypoGeoMean{T},
    ) where T
    @assert cone.grad_updated
    u = cone.point[1]
    @views w = cone.point[2:end]
    z = cone.z
    iw_dim = cone.iw_dim
    wgeoz = iw_dim * cone.wgeo / z
    wgeozm1 = wgeoz - iw_dim
    constww = wgeoz + 1

    @inbounds @views for j in 1:size(arr, 2)
        arr_u = arr[1, j]
        auz = arr_u / z
        prod_w = prod[2:end, j]
        @. prod_w = arr[2:end, j] / w
        dot1 = sum(prod_w)
        prod[1, j] = (auz - wgeoz * dot1) / z
        dot2 = wgeoz * (-auz + wgeozm1 * dot1)
        @. prod_w = (dot2 + constww * prod_w) / w
    end

    return prod
end

function update_inv_hess(cone::HypoGeoMean{T}) where T
    @assert !cone.inv_hess_updated
    isdefined(cone, :inv_hess) || alloc_inv_hess!(cone)
    Hi = cone.inv_hess.data
    u = cone.point[1]
    @views w = cone.point[2:end]
    w_dim = length(w)
    wgeoid = cone.wgeo * cone.iw_dim
    denom = cone.dim * cone.wgeo - w_dim * u
    zd2 = w_dim * cone.z / denom

    Hi[1, 1] = cone.wgeo * (cone.dim * wgeoid - 2 * u) + abs2(u)
    @inbounds for j in eachindex(w)
        j1 = j + 1
        wj = w[j]
        wgeowj = wgeoid * wj
        Hi[1, j1] = wgeowj
        wgeowjd = wgeowj / denom
        @inbounds for i in 1:(j - 1)
            Hi[i + 1, j1] = wgeowjd * w[i]
        end
        Hi[j1, j1] = (wgeowjd + zd2 * wj) * wj
    end

    cone.inv_hess_updated = true
    return cone.inv_hess
end

function inv_hess_prod!(
    prod::AbstractVecOrMat{T},
    arr::AbstractVecOrMat{T},
    cone::HypoGeoMean{T},
    ) where T
    u = cone.point[1]
    @views w = cone.point[2:end]
    w_dim = length(w)
    wgeo = cone.wgeo
    wgeoid = wgeo * cone.iw_dim
    const1 = wgeo * (cone.dim * wgeoid - 2 * u) + abs2(u)
    denom = cone.dim * wgeo - w_dim * u
    zd2 = w_dim * cone.z / denom

    @inbounds @views for j in 1:size(prod, 2)
        arr_u = arr[1, j]
        prod_w = prod[2:end, j]
        @. prod_w = w * arr[2:end, j]
        dot1 = sum(prod_w) * wgeoid
        prod[1, j] = dot1 + const1 * arr_u
        dot2 = dot1 / denom + arr_u * wgeoid
        @. prod_w = (dot2 + zd2 * prod_w) * w
    end

    return prod
end

function dder3(cone::HypoGeoMean, dir::AbstractVector)
    @assert cone.grad_updated
    u = cone.point[1]
    @views w = cone.point[2:end]
    u_dir = dir[1]
    @views w_dir = dir[2:end]
    dder3 = cone.dder3
    z = cone.z
    wdw = cone.tempw
    iw_dim = cone.iw_dim

    piz = cone.wgeo / z
    @. wdw = w_dir / w
    udz = u_dir / z
    uz = u / z
    const6 = -2 * udz * piz
    awdw = iw_dim * sum(wdw)
    const1 = awdw * piz * (2 * piz - 1)
    awdw2 = iw_dim * sum(abs2, wdw)
    dder3[1] = (abs2(udz) + const6 * awdw + (const1 * awdw + piz * awdw2) / 2) / -z

    const2 = piz * (1 - piz)
    const3 = iw_dim * ((const6 * udz + const2 * awdw2 -
        uz * const1 * awdw) / -2 - udz * const1)
    const4 = -iw_dim * (const2 * awdw + udz * piz)
    const5 = iw_dim * (piz + iw_dim * (const2 + piz * uz)) + 1
    @inbounds for (j, wdwj) in enumerate(wdw)
        dder3[j + 1] = ((const4 + const5 * wdwj) * wdwj + const3) / w[j]
    end

    return dder3
end
