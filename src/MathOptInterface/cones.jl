#=
definitions of conic sets not already defined by MathOptInterface
and functions for converting between Hypatia and MOI cone definitions
=#

cone_from_moi(::Type{<:Real}, cone::MOI.AbstractVectorSet) =
    error("MOI set $cone is not recognized")

# MOI predefined cones

cone_from_moi(::Type{T}, cone::MOI.Nonnegatives) where {T <: Real} =
    Cones.Nonnegative{T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.PositiveSemidefiniteConeTriangle) where {T <: Real} =
    Cones.PosSemidefTri{T, T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.NormInfinityCone) where {T <: Real} =
    Cones.EpiNormInf{T, T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.NormOneCone) where {T <: Real} =
    Cones.EpiNormInf{T, T}(MOI.dimension(cone), use_dual = true)

cone_from_moi(::Type{T}, cone::MOI.SecondOrderCone) where {T <: Real} =
    Cones.EpiNormEucl{T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.RotatedSecondOrderCone) where {T <: Real} =
    Cones.EpiPerSquare{T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.NormSpectralCone) where {T <: Real} =
    Cones.EpiNormSpectral{T, T}(extrema((cone.row_dim, cone.column_dim))...)

cone_from_moi(::Type{T}, cone::MOI.NormNuclearCone) where {T <: Real} =
    Cones.EpiNormSpectral{T, T}(extrema((cone.row_dim, cone.column_dim))...,
    use_dual = true)

cone_from_moi(::Type{T}, cone::MOI.PowerCone{T}) where {T <: Real} =
    Cones.GeneralizedPower{T}(T[cone.exponent, 1 - cone.exponent], 1)

cone_from_moi(::Type{T}, cone::MOI.DualPowerCone{T}) where {T <: Real} =
    Cones.GeneralizedPower{T}(T[cone.exponent, 1 - cone.exponent], 1,
    use_dual = true)

cone_from_moi(::Type{T}, cone::MOI.GeometricMeanCone) where {T <: Real} =
    (l = MOI.dimension(cone) - 1; Cones.HypoGeoMean{T}(1 + l))

cone_from_moi(::Type{T}, cone::MOI.RootDetConeTriangle) where {T <: Real} =
    Cones.HypoRootdetTri{T, T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.ExponentialCone) where {T <: Real} =
    Cones.HypoPerLog{T}(3)

cone_from_moi(::Type{T}, cone::MOI.DualExponentialCone) where {T <: Real} =
    Cones.HypoPerLog{T}(3, use_dual = true)

cone_from_moi(::Type{T}, cone::MOI.LogDetConeTriangle) where {T <: Real} =
    Cones.HypoPerLogdetTri{T, T}(MOI.dimension(cone))

cone_from_moi(::Type{T}, cone::MOI.RelativeEntropyCone) where {T <: Real} =
    Cones.EpiRelEntropy{T}(MOI.dimension(cone))

# transformations fallbacks
untransform_affine(::MOI.AbstractVectorSet, vals::AbstractVector) = vals
needs_untransform(::MOI.AbstractVectorSet) = false
needs_rescale(::MOI.AbstractVectorSet) = false
needs_permute(::MOI.AbstractVectorSet) = false

# transformations (transposition of matrix) for MOI rectangular matrix
# cones with matrix of more rows than columns
const SpecNucCone = Union{
    MOI.NormSpectralCone,
    MOI.NormNuclearCone,
    }

needs_untransform(cone::SpecNucCone) = (cone.row_dim > cone.column_dim)

function untransform_affine(cone::SpecNucCone, vals::AbstractVector)
    if needs_untransform(cone)
        @views vals[2:end] = reshape(vals[2:end], cone.column_dim, cone.row_dim)'
    end
    return vals
end

needs_permute(cone::SpecNucCone) = needs_untransform(cone)

function permute_affine(cone::SpecNucCone, vals::AbstractVector{T}) where {T}
    w_vals = reshape(vals[2:end], cone.row_dim, cone.column_dim)'
    return vcat(vals[1], vec(w_vals))
end

function permute_affine(cone::SpecNucCone, func::VAF{T}) where {T}
    terms = func.terms
    idxs_new = zeros(Int, length(terms))
    for k in eachindex(idxs_new)
        i = terms[k].output_index
        @assert i >= 1
        if i <= 2
            idxs_new[k] = i
            continue
        end
        (col_old, row_old) = divrem(i - 2, cone.row_dim)
        k_idx = row_old * cone.column_dim + col_old + 2
        idxs_new[k] = terms[k_idx].output_index
    end
    return idxs_new
end

# transformations (svec rescaling) for MOI symmetric matrix cones not
# in svec (scaled lower triangle) form
const SvecCone = Union{
    MOI.PositiveSemidefiniteConeTriangle,
    MOI.LogDetConeTriangle,
    MOI.RootDetConeTriangle,
    }

svec_offset(::MOI.PositiveSemidefiniteConeTriangle) = 1
svec_offset(::MOI.RootDetConeTriangle) = 2
svec_offset(::MOI.LogDetConeTriangle) = 3

needs_untransform(::SvecCone) = true

function untransform_affine(cone::SvecCone, vals::AbstractVector{T}) where {T}
    @views svec_vals = vals[svec_offset(cone):end]
    Cones.scale_svec!(svec_vals, inv(sqrt(T(2))))
    return vals
end

needs_rescale(::SvecCone) = true

function rescale_affine(cone::SvecCone, vals::AbstractVector{T}) where {T}
    @views svec_vals = vals[svec_offset(cone):end]
    Cones.scale_svec!(svec_vals, sqrt(T(2)))
    return vals
end

function rescale_affine(
    cone::SvecCone,
    func::VAF{T},
    vals::AbstractVector{T},
    ) where {T}
    scal_start = svec_offset(cone) - 1
    rt2 = sqrt(T(2))
    for i in eachindex(vals)
        k = func.terms[i].output_index - scal_start
        if k > 0 && !MOI.Utilities.is_diagonal_vectorized_index(k)
            vals[i] *= rt2
        end
    end
    return vals
end

# Hypatia predefined cones
# some are equivalent to above MOI predefined cones, but we define again for the sake of consistency

"""
$(TYPEDEF)

See [`Cones.Nonnegative`](@ref).

$(TYPEDFIELDS)
"""
struct NonnegativeCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
end
export NonnegativeCone

MOI.dimension(cone::NonnegativeCone) = cone.dim

cone_from_moi(::Type{T}, cone::NonnegativeCone{T}) where {T <: Real} =
    Cones.Nonnegative{T}(cone.dim)

"""
$(TYPEDEF)

See [`Cones.PosSemidefTri`](@ref).

$(TYPEDFIELDS)
"""
struct PosSemidefTriCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    dim::Int
end
export PosSemidefTriCone

MOI.dimension(cone::PosSemidefTriCone) = cone.dim

cone_from_moi(::Type{T}, cone::PosSemidefTriCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.PosSemidefTri{T, R}(cone.dim)

"""
$(TYPEDEF)

See [`Cones.DoublyNonnegativeTri`](@ref).

$(TYPEDFIELDS)
"""
struct DoublyNonnegativeTriCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export DoublyNonnegativeTriCone

DoublyNonnegativeTriCone{T}(dim::Int) where {T <: Real} =
    DoublyNonnegativeTriCone{T}(dim, false)

MOI.dimension(cone::DoublyNonnegativeTriCone where {T <: Real}) = cone.dim

cone_from_moi(::Type{T}, cone::DoublyNonnegativeTriCone{T}) where {T <: Real} =
    Cones.DoublyNonnegativeTri{T}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.PosSemidefTriSparse`](@ref).

$(TYPEDFIELDS)
"""
struct PosSemidefTriSparseCone{I <: Cones.PSDSparseImpl, T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    side::Int
    row_idxs::Vector{Int}
    col_idxs::Vector{Int}
    use_dual::Bool
end
export PosSemidefTriSparseCone

PosSemidefTriSparseCone{I, T, R}(side::Int, row_idxs::Vector{Int}, col_idxs::Vector{Int}) where {I <: Cones.PSDSparseImpl, T <: Real, R <: RealOrComplex{T}} =
    PosSemidefTriSparseCone{I, T, R}(side, row_idxs, col_idxs, false)

MOI.dimension(cone::PosSemidefTriSparseCone{<:Cones.PSDSparseImpl, T, T} where {T <: Real}) =
    length(cone.row_idxs)

MOI.dimension(cone::PosSemidefTriSparseCone{<:Cones.PSDSparseImpl, T, Complex{T}} where {T <: Real}) =
    (2 * length(cone.row_idxs) - cone.side)

cone_from_moi(::Type{T}, cone::PosSemidefTriSparseCone{I, T, R}) where {I <: Cones.PSDSparseImpl, T <: Real, R <: RealOrComplex{T}} =
    Cones.PosSemidefTriSparse{I, T, R}(cone.side, cone.row_idxs, cone.col_idxs,
    use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.LinMatrixIneq`](@ref).

$(TYPEDFIELDS)
"""
struct LinMatrixIneqCone{T <: Real} <: MOI.AbstractVectorSet
    As::Vector
    use_dual::Bool
end
export LinMatrixIneqCone

LinMatrixIneqCone{T}(As::Vector) where {T <: Real} =
    LinMatrixIneqCone{T}(As, false)

MOI.dimension(cone::LinMatrixIneqCone) = length(cone.As)

cone_from_moi(::Type{T}, cone::LinMatrixIneqCone{T}) where {T <: Real} =
    Cones.LinMatrixIneq{T}(cone.As, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.EpiNormInf`](@ref).

$(TYPEDFIELDS)
"""
struct EpiNormInfCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export EpiNormInfCone

EpiNormInfCone{T, R}(dim::Int) where {T <: Real, R <: RealOrComplex{T}} =
    EpiNormInfCone{T, R}(dim, false)

MOI.dimension(cone::EpiNormInfCone) = cone.dim

cone_from_moi(::Type{T}, cone::EpiNormInfCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.EpiNormInf{T, R}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.EpiNormEucl`](@ref).

$(TYPEDFIELDS)
"""
struct EpiNormEuclCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
end
export EpiNormEuclCone

MOI.dimension(cone::EpiNormEuclCone) = cone.dim

cone_from_moi(::Type{T}, cone::EpiNormEuclCone{T}) where {T <: Real} =
    Cones.EpiNormEucl{T}(cone.dim)

"""
$(TYPEDEF)

See [`Cones.EpiPerSquare`](@ref).

$(TYPEDFIELDS)
"""
struct EpiPerSquareCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
end
export EpiPerSquareCone

MOI.dimension(cone::EpiPerSquareCone) = cone.dim

cone_from_moi(::Type{T}, cone::EpiPerSquareCone{T}) where {T <: Real} =
    Cones.EpiPerSquare{T}(cone.dim)

"""
$(TYPEDEF)

See [`Cones.EpiNormSpectralTri`](@ref).

$(TYPEDFIELDS)
"""
struct EpiNormSpectralTriCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export EpiNormSpectralTriCone

EpiNormSpectralTriCone{T, R}(dim::Int) where {T <: Real, R <: RealOrComplex{T}} =
    EpiNormSpectralTriCone{T, R}(dim, false)

MOI.dimension(cone::EpiNormSpectralTriCone) = cone.dim

cone_from_moi(::Type{T}, cone::EpiNormSpectralTriCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.EpiNormSpectralTri{T, R}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.EpiNormSpectral`](@ref).

$(TYPEDFIELDS)
"""
struct EpiNormSpectralCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    d1::Int
    d2::Int
    use_dual::Bool
end
export EpiNormSpectralCone

EpiNormSpectralCone{T, R}(d1::Int, d2::Int) where {T <: Real, R <: RealOrComplex{T}} =
    EpiNormSpectralCone{T, R}(d1, d2, false)

MOI.dimension(cone::EpiNormSpectralCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    1 + Cones.vec_length(R, cone.d1 * cone.d2)

cone_from_moi(::Type{T}, cone::EpiNormSpectralCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.EpiNormSpectral{T, R}(cone.d1, cone.d2, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.MatrixEpiPerSquare`](@ref).

$(TYPEDFIELDS)
"""
struct MatrixEpiPerSquareCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    d1::Int
    d2::Int
    use_dual::Bool
end
export MatrixEpiPerSquareCone

MatrixEpiPerSquareCone{T, R}(d1::Int, d2::Int) where {T <: Real, R <: RealOrComplex{T}} =
    MatrixEpiPerSquareCone{T, R}(d1, d2, false)

MOI.dimension(cone::MatrixEpiPerSquareCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.svec_length(R, cone.d1) + 1 + Cones.vec_length(R, cone.d1 * cone.d2)

cone_from_moi(::Type{T}, cone::MatrixEpiPerSquareCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.MatrixEpiPerSquare{T, R}(cone.d1, cone.d2, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.GeneralizedPower`](@ref).

$(TYPEDFIELDS)
"""
struct GeneralizedPowerCone{T <: Real} <: MOI.AbstractVectorSet
    α::Vector{T}
    n::Int
    use_dual::Bool
end
export GeneralizedPowerCone

GeneralizedPowerCone{T}(α::Vector{T}, n::Int) where {T <: Real} =
    GeneralizedPowerCone{T}(α, n, false)

MOI.dimension(cone::GeneralizedPowerCone) = length(cone.α) + cone.n

cone_from_moi(::Type{T}, cone::GeneralizedPowerCone{T}) where {T <: Real} =
    Cones.GeneralizedPower{T}(cone.α, cone.n, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.HypoPowerMean`](@ref).

$(TYPEDFIELDS)
"""
struct HypoPowerMeanCone{T <: Real} <: MOI.AbstractVectorSet
    α::Vector{T}
    use_dual::Bool
end
export HypoPowerMeanCone

HypoPowerMeanCone{T}(α::Vector{T}) where {T <: Real} =
    HypoPowerMeanCone{T}(α, false)

MOI.dimension(cone::HypoPowerMeanCone) = 1 + length(cone.α)

cone_from_moi(::Type{T}, cone::HypoPowerMeanCone{T}) where {T <: Real} =
    Cones.HypoPowerMean{T}(cone.α, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.HypoGeoMean`](@ref).

$(TYPEDFIELDS)
"""
struct HypoGeoMeanCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export HypoGeoMeanCone

HypoGeoMeanCone{T}(dim::Int) where {T <: Real} = HypoGeoMeanCone{T}(dim, false)

MOI.dimension(cone::HypoGeoMeanCone) = cone.dim

cone_from_moi(::Type{T}, cone::HypoGeoMeanCone{T}) where {T <: Real} =
    Cones.HypoGeoMean{T}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.HypoRootdetTri`](@ref).

$(TYPEDFIELDS)
"""
struct HypoRootdetTriCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export HypoRootdetTriCone

HypoRootdetTriCone{T, R}(dim::Int) where {T <: Real, R <: RealOrComplex{T}} =
    HypoRootdetTriCone{T, R}(dim, false)

MOI.dimension(cone::HypoRootdetTriCone where {T <: Real}) = cone.dim

cone_from_moi(::Type{T}, cone::HypoRootdetTriCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.HypoRootdetTri{T, R}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.HypoPerLog`](@ref).

$(TYPEDFIELDS)
"""
struct HypoPerLogCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export HypoPerLogCone

HypoPerLogCone{T}(dim::Int) where {T <: Real} = HypoPerLogCone{T}(dim, false)

MOI.dimension(cone::HypoPerLogCone) = cone.dim

cone_from_moi(::Type{T}, cone::HypoPerLogCone{T}) where {T <: Real} =
    Cones.HypoPerLog{T}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.HypoPerLogdetTri`](@ref).

$(TYPEDFIELDS)
"""
struct HypoPerLogdetTriCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export HypoPerLogdetTriCone

HypoPerLogdetTriCone{T, R}(dim::Int) where {T <: Real, R <: RealOrComplex{T}} =
    HypoPerLogdetTriCone{T, R}(dim, false)

MOI.dimension(cone::HypoPerLogdetTriCone) = cone.dim

cone_from_moi(::Type{T}, cone::HypoPerLogdetTriCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.HypoPerLogdetTri{T, R}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.EpiPerSepSpectral`](@ref).

$(TYPEDFIELDS)
"""
struct EpiPerSepSpectralCone{T <: Real} <: MOI.AbstractVectorSet
    h::Cones.SepSpectralFun
    Q::Type{<:Cones.ConeOfSquares{T}}
    d::Int
    use_dual::Bool
end
export EpiPerSepSpectralCone

EpiPerSepSpectralCone{T}(h::Cones.SepSpectralFun, Q::Type{<:Cones.ConeOfSquares{T}},
    d::Int) where {T <: Real} =
    EpiPerSepSpectralCone{T}(h, Q, d, false)

MOI.dimension(cone::EpiPerSepSpectralCone) = 2 + Cones.vector_dim(cone.Q, cone.d)

cone_from_moi(::Type{T}, cone::EpiPerSepSpectralCone{T}) where {T <: Real} =
    Cones.EpiPerSepSpectral{cone.Q, T}(cone.h, cone.d, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.EpiRelEntropy`](@ref).

$(TYPEDFIELDS)
"""
struct EpiRelEntropyCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export EpiRelEntropyCone

EpiRelEntropyCone{T}(dim::Int) where {T <: Real} = EpiRelEntropyCone{T}(dim, false)

MOI.dimension(cone::EpiRelEntropyCone) = cone.dim

cone_from_moi(::Type{T}, cone::EpiRelEntropyCone{T}) where {T <: Real} =
    Cones.EpiRelEntropy{T}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.EpiTrRelEntropyTri`](@ref).

$(TYPEDFIELDS)
"""
struct EpiTrRelEntropyTriCone{T <: Real} <: MOI.AbstractVectorSet
    dim::Int
    use_dual::Bool
end
export EpiTrRelEntropyTriCone

EpiTrRelEntropyTriCone{T}(dim::Int) where {T <: Real} =
    EpiTrRelEntropyTriCone{T}(dim, false)

MOI.dimension(cone::EpiTrRelEntropyTriCone where {T <: Real}) = cone.dim

cone_from_moi(::Type{T}, cone::EpiTrRelEntropyTriCone{T}) where {T <: Real} =
    Cones.EpiTrRelEntropyTri{T}(cone.dim, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.WSOSInterpNonnegative`](@ref).

$(TYPEDFIELDS)
"""
struct WSOSInterpNonnegativeCone{T <: Real, R <: RealOrComplex{T}} <: MOI.AbstractVectorSet
    U::Int
    Ps::Vector{Matrix{R}}
    use_dual::Bool
end
export WSOSInterpNonnegativeCone

WSOSInterpNonnegativeCone{T, R}(U::Int, Ps::Vector{Matrix{R}}) where {T <: Real, R <: RealOrComplex{T}} =
    WSOSInterpNonnegativeCone{T, R}(U, Ps, false)

MOI.dimension(cone::WSOSInterpNonnegativeCone) = cone.U

cone_from_moi(::Type{T}, cone::WSOSInterpNonnegativeCone{T, R}) where {T <: Real, R <: RealOrComplex{T}} =
    Cones.WSOSInterpNonnegative{T, R}(cone.U, cone.Ps, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.WSOSInterpPosSemidefTri`](@ref).

$(TYPEDFIELDS)
"""
struct WSOSInterpPosSemidefTriCone{T <: Real} <: MOI.AbstractVectorSet
    R::Int
    U::Int
    Ps::Vector{Matrix{T}}
    use_dual::Bool
end
export WSOSInterpPosSemidefTriCone

WSOSInterpPosSemidefTriCone{T}(R::Int, U::Int, Ps::Vector{Matrix{T}}) where {T <: Real} =
    WSOSInterpPosSemidefTriCone{T}(R, U, Ps, false)

MOI.dimension(cone::WSOSInterpPosSemidefTriCone) = cone.U * Cones.svec_length(cone.R)

cone_from_moi(::Type{T}, cone::WSOSInterpPosSemidefTriCone{T}) where {T <: Real} =
    Cones.WSOSInterpPosSemidefTri{T}(cone.R, cone.U, cone.Ps,
    use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.WSOSInterpEpiNormOne`](@ref).

$(TYPEDFIELDS)
"""
struct WSOSInterpEpiNormOneCone{T <: Real} <: MOI.AbstractVectorSet
    R::Int
    U::Int
    Ps::Vector{Matrix{T}}
    use_dual::Bool
end
export WSOSInterpEpiNormOneCone

WSOSInterpEpiNormOneCone{T}(R::Int, U::Int, Ps::Vector{Matrix{T}}) where {T <: Real} =
    WSOSInterpEpiNormOneCone{T}(R, U, Ps, false)

MOI.dimension(cone::WSOSInterpEpiNormOneCone) = cone.U * cone.R

cone_from_moi(::Type{T}, cone::WSOSInterpEpiNormOneCone{T}) where {T <: Real} =
    Cones.WSOSInterpEpiNormOne{T}(cone.R, cone.U, cone.Ps, use_dual = cone.use_dual)

"""
$(TYPEDEF)

See [`Cones.WSOSInterpEpiNormEucl`](@ref).

$(TYPEDFIELDS)
"""
struct WSOSInterpEpiNormEuclCone{T <: Real} <: MOI.AbstractVectorSet
    R::Int
    U::Int
    Ps::Vector{Matrix{T}}
    use_dual::Bool
end
export WSOSInterpEpiNormEuclCone

WSOSInterpEpiNormEuclCone{T}(R::Int, U::Int, Ps::Vector{Matrix{T}}) where {T <: Real} =
    WSOSInterpEpiNormEuclCone{T}(R, U, Ps, false)

MOI.dimension(cone::WSOSInterpEpiNormEuclCone) = cone.U * cone.R

cone_from_moi(::Type{T}, cone::WSOSInterpEpiNormEuclCone{T}) where {T <: Real} =
    Cones.WSOSInterpEpiNormEucl{T}(cone.R, cone.U, cone.Ps, use_dual = cone.use_dual)

# all cones

const HypatiaCones{T <: Real} = Union{
    NonnegativeCone{T},
    PosSemidefTriCone{T, T},
    PosSemidefTriCone{T, Complex{T}},
    DoublyNonnegativeTriCone{T},
    PosSemidefTriSparseCone{<:Cones.PSDSparseImpl, T, T},
    PosSemidefTriSparseCone{<:Cones.PSDSparseImpl, T, Complex{T}},
    LinMatrixIneqCone{T},
    EpiNormInfCone{T, T},
    EpiNormInfCone{T, Complex{T}},
    EpiNormEuclCone{T},
    EpiPerSquareCone{T},
    EpiNormSpectralTriCone{T, T},
    EpiNormSpectralTriCone{T, Complex{T}},
    EpiNormSpectralCone{T, T},
    EpiNormSpectralCone{T, Complex{T}},
    MatrixEpiPerSquareCone{T, T},
    MatrixEpiPerSquareCone{T, Complex{T}},
    GeneralizedPowerCone{T},
    HypoPowerMeanCone{T},
    HypoGeoMeanCone{T},
    HypoRootdetTriCone{T, T},
    HypoRootdetTriCone{T, Complex{T}},
    HypoPerLogCone{T},
    HypoPerLogdetTriCone{T, T},
    HypoPerLogdetTriCone{T, Complex{T}},
    EpiPerSepSpectralCone{T},
    EpiRelEntropyCone{T},
    EpiTrRelEntropyTriCone{T},
    WSOSInterpNonnegativeCone{T, T},
    WSOSInterpNonnegativeCone{T, Complex{T}},
    WSOSInterpPosSemidefTriCone{T},
    WSOSInterpEpiNormOneCone{T},
    WSOSInterpEpiNormEuclCone{T},
    }

const SupportedCone{T <: Real} = Union{
    HypatiaCones{T},
    MOI.Nonnegatives,
    MOI.PositiveSemidefiniteConeTriangle,
    MOI.NormInfinityCone,
    MOI.NormOneCone,
    MOI.SecondOrderCone,
    MOI.RotatedSecondOrderCone,
    MOI.NormSpectralCone,
    MOI.NormNuclearCone,
    MOI.PowerCone{T},
    MOI.DualPowerCone{T},
    MOI.GeometricMeanCone,
    MOI.RootDetConeTriangle,
    MOI.ExponentialCone,
    MOI.DualExponentialCone,
    MOI.LogDetConeTriangle,
    MOI.RelativeEntropyCone,
    }

Base.copy(cone::HypatiaCones) = cone # maybe should deep copy the cone struct, but this is expensive
