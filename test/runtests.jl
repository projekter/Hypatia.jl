#=
Copyright 2018, Chris Coey, Lea Kapelevich and contributors
=#

import Hypatia
const HYP = Hypatia
const CO = HYP.Cones
# const LS = HYP.LinearSystems
const MO = HYP.Models
const IP = HYP.InteriorPoints
const MU = HYP.ModelUtilities

import Random
using LinearAlgebra
using SparseArrays
using Test


include(joinpath(@__DIR__, "interpolation.jl"))

examples_dir = joinpath(@__DIR__, "../examples")

include(joinpath(examples_dir, "envelope/native.jl"))
include(joinpath(examples_dir, "linearopt/native.jl"))
include(joinpath(examples_dir, "namedpoly/native.jl"))

include(joinpath(@__DIR__, "native.jl"))

# include(joinpath(examples_dir, "envelope/jump.jl"))
# include(joinpath(examples_dir, "expdesign/jump.jl"))
# include(joinpath(examples_dir, "namedpoly/jump.jl"))
# include(joinpath(examples_dir, "shapeconregr/jump.jl"))
# include(joinpath(examples_dir, "densityest/jump.jl"))
# include(joinpath(examples_dir, "wsosmatrix/sosmatrix.jl"))
# include(joinpath(examples_dir, "wsosmatrix/muconvexity.jl"))
# include(joinpath(examples_dir, "wsosmatrix/sosmat1.jl"))
# include(joinpath(examples_dir, "wsosmatrix/sosmat2.jl"))
# include(joinpath(examples_dir, "wsosmatrix/sosmat3.jl"))
#
# include(joinpath(@__DIR__, "JuMP.jl"))
#
# include(joinpath(@__DIR__, "MOI_wrapper.jl"))


@testset "Hypatia tests" begin

@info("starting interpolation tests")
@testset "interpolation tests" begin
    fekete_sample()
end

# # @info("starting native interface tests")
# verbose = true
# # linearsystems = [
# #     LS.QRSymm,
# #     # LS.Naive,
# #     ]
# testfuns = [
#     # dimension1, # TODO needs preprocessing
#     # consistent1,
#     # inconsistent1,
#     # inconsistent2,
#     orthant1,
#     orthant2,
#     orthant3,
#     orthant4,
#     epinorminf1,
#     epinorminf2,
#     epinorminf3,
#     epinorminf4,
#     epinorminf5,
#     epinorminf6,
#     epinormeucl1,
#     epinormeucl2,
#     epipersquare1,
#     epipersquare2,
#     epipersquare3,
#     # semidefinite1,
#     # semidefinite2,
#     # semidefinite3,
#     hypoperlog1,
#     hypoperlog2,
#     hypoperlog3,
#     hypoperlog4,
#     epiperpower1,
#     epiperpower2,
#     epiperpower3,
#     hypogeomean1,
#     hypogeomean2,
#     hypogeomean3,
#     hypogeomean4,
#     epinormspectral1,
#     hypoperlogdet1,
#     hypoperlogdet2,
#     hypoperlogdet3,
#     epipersumexp1,
#     epipersumexp2,
#     ]
# # @testset "native tests: $t, $l" for t in testfuns, l in linearsystems
# @testset "native tests: $t" for t in testfuns
#     # t(verbose = verbose, linearsystem=l)
#     t(verbose = verbose)
# end
#
# @info("starting default native examples tests")
# testfuns = [
#     run_envelope_primal_dense,
#     run_envelope_dual_dense,
#     run_envelope_primal_sparse,
#     run_envelope_dual_sparse,
#     run_linearopt,
#     run_namedpoly,
#     ]
# @testset "default examples: $t" for t in testfuns
#     t()
# end
#
# @info("starting additional native examples tests")
# verbose = false
# # linearsystems = [
# #     LS.QRSymm,
# #     # LS.Naive, # slow
# #     ]
# testfuns = [
#     # TODO test primal and dual formulations of envelope
#     # envelope1, # TODO check slight obj disagreement
#     envelope2,
#     envelope3,
#     envelope4,
#     linearopt1,
#     linearopt2,
#     # namedpoly1,
#     # namedpoly2,
#     namedpoly3,
#     # namedpoly4,
#     namedpoly5,
#     # namedpoly6,
#     namedpoly7,
#     # namedpoly8,
#     namedpoly9,
#     namedpoly10,
#     namedpoly11,
#     ]
# # @testset "native examples: $t, $l" for t in testfuns, l in linearsystems
# @testset "native examples: $t" for t in testfuns#, l in linearsystems
#     # t(verbose = verbose, linearsystem=l)
#     t(verbose = verbose)
# end

# @info("starting default JuMP examples tests")
# testfuns = [
#     run_JuMP_envelope_boxinterp,
#     run_JuMP_envelope_sampleinterp_box,
#     run_JuMP_envelope_sampleinterp_ball,
#     run_JuMP_expdesign,
#     run_JuMP_namedpoly_PSD, # TODO check: final objective doesn't match
#     run_JuMP_namedpoly_WSOS_primal,
#     run_JuMP_namedpoly_WSOS_dual,
#     run_JuMP_shapeconregr_PSD,
#     run_JuMP_shapeconregr_WSOS,
#     run_JuMP_densityest,
#     run_JuMP_sosmatrix_rand,
#     run_JuMP_sosmatrix_a,
#     run_JuMP_sosmatrix_poly_a,
#     run_JuMP_sosmatrix_poly_b,
#     run_JuMP_muconvexity_rand,
#     run_JuMP_muconvexity_a,
#     run_JuMP_muconvexity_b,
#     run_JuMP_muconvexity_c,
#     run_JuMP_muconvexity_d,
#     run_JuMP_sosmat1,
#     run_JuMP_sosmat2_scalar,
#     run_JuMP_sosmat2_matrix,
#     run_JuMP_sosmat2_matrix_dual,
#     run_JuMP_sosmat3, # numerically unstable
#     ]
# @testset "default examples: $t" for t in testfuns
#     t()
# end
#
# @info("starting additional JuMP examples tests")
# testfuns = [
#     namedpoly1_JuMP,
#     namedpoly2_JuMP,
#     namedpoly3_JuMP,
#     namedpoly4_JuMP, # numerically unstable
#     namedpoly5_JuMP,
#     namedpoly6_JuMP,
#     namedpoly7_JuMP,
#     namedpoly8_JuMP,
#     namedpoly9_JuMP,
#     namedpoly10_JuMP,
#     shapeconregr1_JuMP,
#     shapeconregr2_JuMP,
#     shapeconregr3_JuMP,
#     shapeconregr4_JuMP,
#     shapeconregr5_JuMP,
#     shapeconregr6_JuMP,
#     shapeconregr7_JuMP, # numerically unstable
#     shapeconregr8_JuMP,
#     shapeconregr9_JuMP, # numerically unstable
#     shapeconregr10_JuMP, # numerically unstable
#     shapeconregr11_JuMP, # numerically unstable
#     shapeconregr12_JuMP, # numerically unstable
#     shapeconregr13_JuMP, # numerically unstable
#     # shapeconregr14_JuMP, # throws out-of-memory error
#     # shapeconregr15_JuMP, # throws out-of-memory error
#     ]
# @testset "JuMP examples: $t" for t in testfuns
#     t()
# end
#
# @info("starting MathOptInterface tests")
# verbose = false
# linearsystems = [
#     LS.QRSymm,
#     LS.Naive,
#     ]
# @testset "MOI tests: $l, $(d ? "dense" : "sparse")" for l in linearsystems, d in [false, true]
#     testmoi(verbose = verbose, linearsystem=l, dense=d)
# end

end
