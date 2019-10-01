#=
Copyright 2019, Chris Coey, Lea Kapelevich and contributors

helpers for sparse factorizations and linear solves
=#

import SparseArrays.SparseMatrixCSC
import SuiteSparse

#=
nonsymmetric
=#

abstract type SparseNonSymCache{T <: Real} end

mutable struct UMFPACKNonSymCache{T <: Real} <: SparseNonSymCache{T}
    analyzed::Bool
    umfpack::SuiteSparse.UMFPACK.UmfpackLU
    function UMFPACKNonSymCache{Float64}()
        cache = new{Float64}()
        cache.analyzed = false
        return cache
    end
end
UMFPACKNonSymCache{T}() where {T <: Real} = error("UMFPACK only works with real type Float64")
UMFPACKNonSymCache() = UMFPACKNonSymCache{Float64}()
# NOTE UMFPACK restricts to Int32 if Int(ccall((:jl_cholmod_sizeof_long,:libsuitesparse_wrapper),Csize_t,())) == 4
# easiest to restrict int type to SuiteSparse_long
int_type(::UMFPACKNonSymCache) = SuiteSparse.CHOLMOD.SuiteSparse_long

function update_sparse_fact(cache::UMFPACKNonSymCache, A::SparseMatrixCSC{Float64, Int})
    if !cache.analyzed
        cache.umfpack = lu(A) # symbolic and numeric factorization
        cache.analyzed = true
    else
        # TODO this is a hack around lack of interface https://github.com/JuliaLang/julia/issues/33323
        # update nzval field in the factorizationTimer
        @timeit "copyto" copyto!(cache.umfpack.nzval, A.nzval)
        # do not indicate that the numeric factorization has been computed
        cache.umfpack.numeric = C_NULL
        @timeit "numeric" SuiteSparse.UMFPACK.umfpack_numeric!(cache.umfpack) # will only repeat numeric factorization
    end
    return
end

function solve_sparse_system(cache::UMFPACKNonSymCache, x::Matrix{Float64}, A::SparseMatrixCSC{Float64, Int}, b::Matrix{Float64})
    ldiv!(x, cache.umfpack, b) # will not repeat factorizations
    return x
end

# default to UMFPACK
SparseNonSymCache{Float64}() = UMFPACKNonSymCache{Float64}()
SparseNonSymCache{T}() where {T <: Real} = error("Sparse caches only work with real type Float64")
SparseNonSymCache() = SparseNonSymCache{Float64}()

#=
symmetric
=#

abstract type SparseSymCache{T <: Real} end

mutable struct CHOLMODSymCache{T <: Real} <: SparseSymCache{T}
    analyzed::Bool
    cholmod::SuiteSparse.CHOLMOD.Factor
    diag_pert::Float64
    function CHOLMODSymCache{Float64}(; diag_pert::Float64 = sqrt(eps(Float64)))
        cache = new{Float64}()
        cache.analyzed = false
        cache.diag_pert = diag_pert
        return cache
    end
end
CHOLMODSymCache{T}(; diag_pert = NaN) where {T <: Real} = error("CHOLMOD only works with real type Float64")
CHOLMODSymCache(; diag_pert::Float64 = sqrt(eps(Float64))) = CHOLMODSymCache{Float64}(diag_pert = diag_pert)
int_type(::CHOLMODSymCache) = SuiteSparse.CHOLMOD.SuiteSparse_long

function update_sparse_fact(cache::CHOLMODSymCache, A::SparseMatrixCSC{Float64, SuiteSparse.CHOLMOD.SuiteSparse_long})
    A_symm = Symmetric(A, :L)
    if !cache.analyzed
        cache.cholmod = SuiteSparse.CHOLMOD.ldlt(A_symm, check = false)
        cache.analyzed = true
    else
        ldlt!(cache.cholmod, A_symm, check = true)
    end
    if !issuccess(cache.cholmod)
        # @warn("numerical failure: sparse factorization failed")
        # ldlt!(cache.cholmod, A_symm, shift = 1e-4, check = false)
        # if !issuccess(cache.cholmod)
        #     @warn("numerical failure: sparse factorization failed again")
        #     ldlt!(cache.cholmod, A_symm, shift = 1e-8 * maximum(abs, A[j, j] for j in 1:size(A_symm, 1)), check = false)
        #     if !issuccess(cache.cholmod)
        #         @warn("numerical failure: could not fix sparse factorization failure")
        #     end
        # end
    end
    return
end

function solve_sparse_system(cache::CHOLMODSymCache, x::Matrix{Float64}, A::SparseMatrixCSC{Float64, SuiteSparse.CHOLMOD.SuiteSparse_long}, b::Matrix{Float64})
    x .= cache.cholmod \ b
    return x
end

# default to CHOLMOD
SparseSymCache{Float64}() = CHOLMODSymCache{Float64}()
SparseSymCache{T}() where {T <: Real} = error("Sparse caches only work with real type Float64")
SparseSymCache() = SparseSymCache{Float64}()

#=
helpers
=#

free_memory(::Union{UMFPACKNonSymCache{Float64}, CHOLMODSymCache{Float64}}) = nothing
