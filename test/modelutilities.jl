#=
tests for ModelUtilities module
=#

using Test
import Random
using LinearAlgebra
import DynamicPolynomials
import Hypatia
import Hypatia.ModelUtilities

function test_svec_conversion(T::Type{<:Real})
    tol = 10eps(T)
    rt2 = sqrt(T(2))
    vec = rand(T, 6)
    vec_copy = copy(vec)
    ModelUtilities.vec_to_svec!(vec)
    @test vec ≈ vec_copy .* [1, rt2, 1, rt2, rt2, 1] atol=tol rtol=tol
    copyto!(vec, vec_copy)
    ModelUtilities.vec_to_svec!(vec, incr = 2)
    @test vec ≈ vec_copy .* [1, 1, rt2, rt2, 1, 1] atol=tol rtol=tol
    mat = rand(T, 10, 3)
    mat_copy = copy(mat)
    ModelUtilities.vec_to_svec!(mat)
    @test mat ≈ mat_copy .* [1, rt2, 1, rt2, rt2, 1, rt2, rt2, rt2, 1] atol=tol rtol=tol
    mat = rand(T, 12, 3)
    mat_copy = copy(mat)
    ModelUtilities.vec_to_svec!(mat, incr = 2)
    @test mat ≈ mat_copy .* [1, 1, rt2, rt2, 1, 1, rt2, rt2, rt2, rt2, 1, 1] atol=tol rtol=tol
end

function test_fekete_sample(T::Type{<:Real})
    Random.seed!(1)
    n = 3
    halfdeg = 2
    box = ModelUtilities.Box{T}(-ones(T, n), ones(T, n))
    free = ModelUtilities.FreeDomain{T}(n)

    for sample in (true, false)
        (box_U, box_pts, box_Ps) = ModelUtilities.interpolate(box, halfdeg, sample = sample, sample_factor = 20)
        (free_U, free_pts, free_Ps) = ModelUtilities.interpolate(free, halfdeg, sample = sample, sample_factor = 20)
        @test length(free_Ps) == 1
        @test box_U == free_U
        @test size(box_pts) == size(free_pts)
        @test size(box_Ps[1]) == size(free_Ps[1])
        @test norm(box_Ps[1]) ≈ norm(free_Ps[1]) atol=1e-1 rtol=1e-1
    end
end

function test_cheb2_w(T::Type{<:Real})
    for halfdeg in 1:4
        (U, pts, Ps, V, w) = ModelUtilities.interpolate(ModelUtilities.FreeDomain{T}(1), halfdeg, sample = false, calc_w = true)
        @test dot(w, [sum(pts[i, 1] ^ d for d in 0:(2halfdeg)) for i in 1:U]) ≈ sum(2 / (i + 1) for i in 0:2:(2halfdeg))
    end
end

function test_recover_lagrange_polys(T::Type{<:Real})
    tol = sqrt(eps(T))
    Random.seed!(1)
    n = 1
    deg = 1
    pts = reshape(T[0, 1], 2, 1)
    lagrange_polys = ModelUtilities.recover_lagrange_polys(pts, deg)

    random_pts = rand(T, 5)
    @test lagrange_polys[1].(random_pts) ≈ 1 .- random_pts
    @test lagrange_polys[2].(random_pts) ≈ random_pts

    deg = 2
    pts = reshape(T[0, 1, 2], 3, 1)
    lagrange_polys = ModelUtilities.recover_lagrange_polys(pts, deg)

    random_pts = rand(T, 5)
    @test lagrange_polys[1].(random_pts) ≈ (random_pts .- 1) .* (random_pts .- 2) * 0.5
    @test lagrange_polys[2].(random_pts) ≈ random_pts .* (random_pts .- 2) * -1
    @test lagrange_polys[3].(random_pts) ≈ random_pts .* (random_pts .- 1) * 0.5

    n = 2
    deg = 2
    pts = rand(T, 6, 2)
    lagrange_polys = ModelUtilities.recover_lagrange_polys(pts, deg)

    for i in 1:6, j in 1:6
        @test lagrange_polys[i](pts[j, :]) ≈ (j == i ? 1 : 0) atol=tol rtol=tol
    end

    for n in 1:3, sample in [true, false]
        halfdeg = 2

        (U, pts, Ps, V, w) = ModelUtilities.interpolate(ModelUtilities.FreeDomain{T}(n), halfdeg, sample = sample, calc_V = true, calc_w = true)
        DynamicPolynomials.@polyvar x[1:n]
        monos = DynamicPolynomials.monomials(x, 0:(2 * halfdeg))
        lagrange_polys = ModelUtilities.recover_lagrange_polys(pts, 2 * halfdeg)

        @test size(V) == (size(pts, 1), U)
        @test sum(lagrange_polys) ≈ 1
        @test sum(w[i] * lagrange_polys[j](pts[i, :]) for j in 1:U, i in 1:U) ≈ sum(w) atol=tol rtol=tol
        @test sum(w) ≈ 2^n
    end
end

function test_recover_cheb_polys(T::Type{<:Real})
    DynamicPolynomials.@polyvar x[1:2]
    halfdeg = 2
    monos = DynamicPolynomials.monomials(x, 0:halfdeg)
    cheb_polys = ModelUtilities.get_chebyshev_polys(x, halfdeg)
    @test cheb_polys == [1, x[1], x[2], 2x[1]^2 - 1, x[1] * x[2], 2x[2]^2 - 1]
end
