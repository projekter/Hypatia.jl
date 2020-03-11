#=
Copyright 2020, Chris Coey, Lea Kapelevich and contributors

see description in native.jl
=#

include(joinpath(@__DIR__, "../common_JuMP.jl"))

struct MatrixRegressionJuMP{T <: Real} <: ExampleInstanceJuMP{T}
    Y::Matrix{T}
    X::Matrix{T}
    lam_fro::Real # penalty on Frobenius norm
    lam_nuc::Real # penalty on nuclear norm
    lam_las::Real # penalty on l1 norm
    lam_glr::Real # penalty on penalty on row group l1 norm
    lam_glc::Real # penalty on penalty on column group l1 norm
end
function MatrixRegressionJuMP{Float64}(
    n::Int,
    m::Int,
    p::Int,
    args...;
    A_max_rank::Int = div(m, 2) + 1,
    A_sparsity::Real = max(0.2, inv(sqrt(m * p))),
    Y_noise::Real = 0.01,
    )
    @assert p >= m
    @assert 1 <= A_max_rank <= m
    @assert 0 < A_sparsity <= 1
    A_left = sprandn(p, A_max_rank, A_sparsity)
    A_right = sprandn(A_max_rank, m, A_sparsity)
    A = 10 * A_left * A_right
    X = randn(n, p)
    Y = X * A + Y_noise * randn(n, m)
    return MatrixRegressionJuMP{Float64}(Y, X, args...)
end

options = ()
example_tests(::Type{MatrixRegressionJuMP{Float64}}, ::MinimalInstances) = [
    ((2, 3, 4, 0, 0, 0, 0, 0), false, options),
    ((2, 3, 4, 0.1, 0.1, 0.1, 0.2, 0.2), false, options),
    ]
example_tests(::Type{MatrixRegressionJuMP{Float64}}, ::FastInstances) = [
    ((5, 3, 4, 0, 0, 0, 0, 0), false, options),
    ((5, 3, 4, 0.1, 0.1, 0.1, 0.2, 0.2), false, options),
    ((5, 3, 4, 0, 0.1, 0.1, 0, 0), false, options),
    ((3, 4, 5, 0, 0, 0, 0, 0), false, options),
    ((3, 4, 5, 0.1, 0.1, 0.1, 0.2, 0.2), false, options),
    ((3, 4, 5, 0, 0.1, 0.1, 0, 0), false, options),
    ((10, 20, 20, 0, 0, 0, 0, 0), false, options),
    ((10, 20, 20, 0.1, 0.1, 0.1, 0.2, 0.2), false, options),
    ((10, 20, 20, 0, 0.1, 0.1, 0, 0), false, options),
    ((100, 8, 12, 0, 0, 0, 0, 0), false, options),
    ((100, 8, 12, 0.1, 0.1, 0.1, 0.2, 0.2), false, options),
    ((100, 8, 12, 0, 0.1, 0.1, 0, 0), false, options),
    ]
example_tests(::Type{MatrixRegressionJuMP{Float64}}, ::SlowInstances) = [
    ((15, 20, 50, 0, 0, 0, 0, 0), false, options),
    ((15, 20, 50, 0.1, 0.1, 0.1, 0.2, 0.2), false, options),
    ((15, 20, 50, 0, 0.1, 0.1, 0, 0), false, options),
    ]

function build(inst::MatrixRegressionJuMP{T}) where {T <: Float64} # TODO generic reals
    (Y, X) = (inst.Y, inst.X)
    @assert min(inst.lam_fro, inst.lam_nuc, inst.lam_las, inst.lam_glr, inst.lam_glc) >= 0
    (data_n, data_m) = size(Y)
    data_p = size(X, 2)
    @assert size(X, 1) == data_n
    @assert data_p >= data_m

    Qhalf = (data_n > data_p) ? qr(X).R : X # dimension reduction via QR if helpful

    model = JuMP.Model()
    JuMP.@variable(model, A[1:data_p, 1:data_m])
    JuMP.@variable(model, loss)
    JuMP.@constraint(model, vcat(loss, 0.5, vec(Qhalf * A)) in JuMP.RotatedSecondOrderCone())
    obj = (loss / 2 - dot(X' * Y, A)) / data_n

    if !iszero(inst.lam_fro)
        JuMP.@variable(model, t_fro)
        JuMP.@constraint(model, vcat(t_fro, vec(A)) in JuMP.SecondOrderCone())
        obj += inst.lam_fro * t_fro
    end
    if !iszero(inst.lam_nuc)
        JuMP.@variable(model, t_nuc)
        JuMP.@constraint(model, vcat(t_nuc, vec(A)) in MOI.NormNuclearCone(data_p, data_m))
        obj += inst.lam_nuc * t_nuc
    end
    if !iszero(inst.lam_las)
        JuMP.@variable(model, t_las)
        JuMP.@constraint(model, vcat(t_las, vec(A)) in MOI.NormOneCone(data_p * data_m + 1))
        obj += inst.lam_las * t_las
    end
    if !iszero(inst.lam_glr)
        JuMP.@variable(model, t_glr[1:data_p])
        JuMP.@constraint(model, [i = 1:data_p], vcat(t_glr[i], A[i, :]) in JuMP.SecondOrderCone())
        obj += inst.lam_glr * sum(t_glr)
    end
    if !iszero(inst.lam_glc)
        JuMP.@variable(model, t_glc[1:data_m])
        JuMP.@constraint(model, [i = 1:data_m], vcat(t_glc[i], A[:, i]) in JuMP.SecondOrderCone())
        obj += inst.lam_glc * sum(t_glc)
    end

    JuMP.@objective(model, Min, obj)

    model.ext[:A_var] = A # save for use in tests

    return model
end

function test_extra(inst::MatrixRegressionJuMP, model)
    @test JuMP.termination_status(model) == MOI.OPTIMAL
    if JuMP.termination_status(model) == MOI.OPTIMAL
        # check objective value is correct
        (Y, X) = (inst.Y, inst.X)
        A_opt = JuMP.value.(model.ext[:A_var])
        loss = (sum(abs2, X * A_opt) / 2 - dot(X' * Y, A_opt)) / size(Y, 1)
        obj_try = loss +
            inst.lam_fro * norm(vec(A_opt), 2) +
            inst.lam_nuc * sum(svd(A_opt).S) +
            inst.lam_las * norm(vec(A_opt), 1) +
            inst.lam_glr * sum(norm, eachrow(A_opt)) +
            inst.lam_glc * sum(norm, eachcol(A_opt))
        tol = eps(eltype(X))^0.25
        @test JuMP.objective_value(model) ≈ obj_try atol = tol rtol = tol
    end
end

# @testset "MatrixRegressionJuMP" for inst in example_tests(MatrixRegressionJuMP{Float64}, MinimalInstances()) test(inst...) end

return MatrixRegressionJuMP
