#=
Copyright 2018, Chris Coey and contributors

interior point type and functions for algorithms based on homogeneous self dual embedding
=#

mutable struct Solver{T <: Real}
    # main options
    verbose::Bool
    iter_limit::Int
    time_limit::Float64
    tol_rel_opt::T
    tol_abs_opt::T
    tol_feas::T
    tol_slow::T
    preprocess::Bool
    init_use_iterative::Bool
    init_tol_qr::T
    init_use_fallback::Bool
    max_nbhd::T
    use_infty_nbhd::Bool
    system_solver::SystemSolver{T}

    # current status of the solver object
    status::Symbol

    # solve info and timers
    solve_time::Float64
    timer::TimerOutput
    num_iters::Int

    # model and preprocessed model data
    orig_model::Models.Model{T}
    model::Models.Model{T}
    x_keep_idxs::AbstractVector{Int}
    y_keep_idxs::AbstractVector{Int}
    Ap_R::UpperTriangular{T, <:AbstractMatrix{T}}
    Ap_Q::Union{UniformScaling, AbstractMatrix{T}}

    # current iterate
    point::Models.Point{T}
    tau::T
    kap::T
    mu::T

    # residuals
    x_residual::Vector{T}
    y_residual::Vector{T}
    z_residual::Vector{T}
    x_norm_res_t::T
    y_norm_res_t::T
    z_norm_res_t::T
    x_norm_res::T
    y_norm_res::T
    z_norm_res::T

    # convergence parameters
    primal_obj_t::T
    dual_obj_t::T
    primal_obj::T
    dual_obj::T
    gap::T
    rel_gap::T
    x_feas::T
    y_feas::T
    z_feas::T

    # termination condition helpers
    x_conv_tol::T
    y_conv_tol::T
    z_conv_tol::T
    prev_is_slow::Bool
    prev2_is_slow::Bool
    prev_gap::T
    prev_rel_gap::T
    prev_x_feas::T
    prev_y_feas::T
    prev_z_feas::T

    # step helpers
    keep_iterating::Bool
    prev_aff_alpha::T
    prev_gamma::T
    prev_alpha::T
    z_temp::Vector{T}
    s_temp::Vector{T}
    primal_views
    dual_views
    nbhd_temp
    cones_infeas::Vector{Bool}
    cones_loaded::Vector{Bool}

    function Solver{T}(;
        verbose::Bool = false,
        iter_limit::Int = 1000,
        time_limit::Real = Inf,
        tol_rel_opt::Real = sqrt(eps(T)),
        tol_abs_opt::Real = sqrt(eps(T)),
        tol_feas::Real = sqrt(eps(T)),
        tol_slow::Real = 1e-3,
        preprocess::Bool = true,
        init_use_iterative::Bool = false,
        init_tol_qr::Real = 100 * eps(T),
        init_use_fallback::Bool = true,
        max_nbhd::Real = 0.7,
        use_infty_nbhd::Bool = true,
        system_solver::SystemSolver{T} = QRCholSystemSolver{T}(),
        ) where {T <: Real}
        if isa(system_solver, QRCholSystemSolver{T})
            @assert preprocess # require preprocessing for QRCholSystemSolver
        end

        solver = new{T}()
        solver.verbose = verbose
        solver.iter_limit = iter_limit
        solver.time_limit = time_limit
        solver.tol_rel_opt = tol_rel_opt
        solver.tol_abs_opt = tol_abs_opt
        solver.tol_feas = tol_feas
        solver.tol_slow = tol_slow
        solver.preprocess = preprocess
        solver.init_use_iterative = init_use_iterative
        solver.init_tol_qr = init_tol_qr
        solver.init_use_fallback = init_use_fallback
        solver.max_nbhd = max_nbhd
        solver.use_infty_nbhd = use_infty_nbhd
        solver.system_solver = system_solver
        solver.status = :NotLoaded

        return solver
    end
end

get_timer(solver::Solver) = solver.timer

get_status(solver::Solver) = solver.status
get_solve_time(solver::Solver) = solver.solve_time
get_num_iters(solver::Solver) = solver.num_iters

get_primal_obj(solver::Solver) = solver.primal_obj
get_dual_obj(solver::Solver) = solver.dual_obj

get_s(solver::Solver) = copy(solver.point.s)
get_z(solver::Solver) = copy(solver.point.z)

function get_x(solver::Solver{T}) where {T <: Real}
    if solver.preprocess
        x = zeros(T, solver.orig_model.n)
        x[solver.x_keep_idxs] = solver.point.x # unpreprocess solver's solution
    else
        x = copy(solver.point.x)
    end
    return x
end

function get_y(solver::Solver{T}) where {T <: Real}
    if solver.preprocess
        y = zeros(T, solver.orig_model.p)
        y[solver.y_keep_idxs] = solver.point.y # unpreprocess solver's solution
    else
        y = copy(solver.point.y)
    end
    return y
end

get_tau(solver::Solver) = solver.tau
get_kappa(solver::Solver) = solver.kap
get_mu(solver::Solver) = solver.mu

function load(solver::Solver{T}, model::Models.Model{T}) where {T <: Real}
    # @assert solver.status == :NotLoaded # TODO maybe want a reset function that just keeps options
    solver.orig_model = model
    solver.status = :Loaded
    return solver
end

function solve(solver::Solver{T}) where {T <: Real}
    @assert solver.status == :Loaded
    solver.status = :SolveCalled
    start_time = time()
    solver.num_iters = 0
    solver.solve_time = NaN
    solver.timer = TimerOutput()

    # preprocess and find initial point
    @timeit solver.timer "initialize" begin
        @timeit solver.timer "init_cone" point = solver.point = initialize_cone_point(solver.orig_model.cones, solver.orig_model.cone_idxs)

        @timeit solver.timer "find_point" solver.preprocess ? preprocess_find_initial_point(solver) : find_initial_point(solver)
        solver.status != :SolveCalled && return solver
        model = solver.model

        solver.tau = one(T)
        solver.kap = one(T)
        calc_mu(solver)
        if isnan(solver.mu) || abs(one(T) - solver.mu) > sqrt(eps(T))
            @warn("initial mu is $(solver.mu) but should be 1 (this could indicate a problem with cone barrier oracles)")
        end
        Cones.load_point.(model.cones, point.primal_views)
    end

    # setup iteration helpers
    solver.x_residual = similar(model.c)
    solver.y_residual = similar(model.b)
    solver.z_residual = similar(model.h)
    solver.x_norm_res_t = NaN
    solver.y_norm_res_t = NaN
    solver.z_norm_res_t = NaN
    solver.x_norm_res = NaN
    solver.y_norm_res = NaN
    solver.z_norm_res = NaN

    solver.primal_obj_t = NaN
    solver.dual_obj_t = NaN
    solver.primal_obj = NaN
    solver.dual_obj = NaN
    solver.gap = NaN
    solver.rel_gap = NaN
    solver.x_feas = NaN
    solver.y_feas = NaN
    solver.z_feas = NaN

    solver.x_conv_tol = inv(max(one(T), norm(model.c)))
    solver.y_conv_tol = inv(max(one(T), norm(model.b)))
    solver.z_conv_tol = inv(max(one(T), norm(model.h)))
    solver.prev_is_slow = false
    solver.prev2_is_slow = false
    solver.prev_gap = NaN
    solver.prev_rel_gap = NaN
    solver.prev_x_feas = NaN
    solver.prev_y_feas = NaN
    solver.prev_z_feas = NaN

    solver.prev_aff_alpha = one(T)
    solver.prev_gamma = one(T)
    solver.prev_alpha = one(T)
    solver.z_temp = similar(model.h)
    solver.s_temp = similar(model.h)
    solver.primal_views = [view(Cones.use_dual(model.cones[k]) ? solver.z_temp : solver.s_temp, model.cone_idxs[k]) for k in eachindex(model.cones)]
    solver.dual_views = [view(Cones.use_dual(model.cones[k]) ? solver.s_temp : solver.z_temp, model.cone_idxs[k]) for k in eachindex(model.cones)]
    if !solver.use_infty_nbhd
        solver.nbhd_temp = [Vector{T}(undef, length(model.cone_idxs[k])) for k in eachindex(model.cones)]
    end
    solver.cones_infeas = trues(length(model.cones))
    solver.cones_loaded = trues(length(model.cones))

    @timeit solver.timer "setup_system" load(solver.system_solver, solver)

    # iterate from initial point
    solver.keep_iterating = true
    while solver.keep_iterating
        @timeit solver.timer "calc_res" calc_residual(solver)

        @timeit solver.timer "calc_conv" calc_convergence_params(solver)

        @timeit solver.timer "print_iter" solver.verbose && print_iteration_stats(solver)

        @timeit solver.timer "check_conv" check_convergence(solver) && break

        if solver.num_iters == solver.iter_limit
            solver.verbose && println("iteration limit reached; terminating")
            solver.status = :IterationLimit
            break
        end
        if time() - start_time >= solver.time_limit
            solver.verbose && println("time limit reached; terminating")
            solver.status = :TimeLimit
            break
        end

        @timeit solver.timer "step" step(solver)
        solver.num_iters += 1
    end

    # calculate result and iteration statistics and finish
    point.x ./= solver.tau
    point.y ./= solver.tau
    point.z ./= solver.tau
    point.s ./= solver.tau
    Cones.load_point.(solver.model.cones, point.primal_views)

    solver.solve_time = time() - start_time

    solver.verbose && println("\nstatus is $(solver.status) after $(solver.num_iters) iterations and $(trunc(solver.solve_time, digits=3)) seconds\n")

    return solver
end

function initialize_cone_point(cones::Vector{Cones.Cone{T}}, cone_idxs::Vector{UnitRange{Int}}) where {T <: Real}
    q = isempty(cones) ? 0 : sum(Cones.dimension, cones)
    point = Models.Point(T[], T[], Vector{T}(undef, q), Vector{T}(undef, q), cones, cone_idxs)

    for k in eachindex(cones)
        cone_k = cones[k]
        Cones.setup_data(cone_k)
        primal_k = point.primal_views[k]
        Cones.set_initial_point(primal_k, cone_k)
        Cones.load_point(cone_k, primal_k)
        @assert Cones.is_feas(cone_k)
        g = Cones.grad(cone_k)
        @. point.dual_views[k] = -g
    end

    return point
end

const sparse_QR_reals = Float64

# TODO optionally use row and col scaling on AG and apply to c, b, h
# TODO precondition iterative methods
# TODO pick default tol for iter methods
function find_initial_point(solver::Solver{T}) where {T <: Real}
    model = solver.model = solver.orig_model
    A = model.A
    G = model.G
    n = model.n
    p = model.p
    q = model.q
    point = solver.point

    # solve for x as least squares solution to Ax = b, Gx = h - s
    @timeit solver.timer "initx" if !iszero(n)
        rhs = vcat(model.b, model.h - point.s)
        if solver.init_use_iterative
            # use iterative solvers method TODO pick lsqr or lsmr
            AG = BlockMatrix{T}(p + q, n, [A, G], [1:p, (p + 1):(p + q)], [1:n, 1:n])
            point.x = zeros(T, n)
            IterativeSolvers.lsqr!(point.x, AG, rhs)
        else
            AG = vcat(A, G)
            if issparse(AG) && !(T <: sparse_QR_reals)
                # TODO alternative fallback is to convert sparse{T} to sparse{Float64} and do the sparse LU
                if solver.init_use_fallback
                    @warn("using dense factorization of [A; G] in initial point finding because sparse factorization for number type $T is not supported by SparseArrays")
                    AG = Matrix(AG)
                else
                    error("sparse factorization for number type $T is not supported by SparseArrays, so Hypatia cannot find an initial point")
                end
            end
            @timeit solver.timer "lsqrAG" AG_fact = issparse(AG) ? qr(AG) : qr!(AG)

            AG_rank = get_rank_est(AG_fact, solver.init_tol_qr)
            if AG_rank < n
                @warn("some dual equalities appear to be dependent; try using preprocess = true")
            end

            point.x = AG_fact \ rhs
        end
    end

    # solve for y as least squares solution to A'y = -c - G'z
    @timeit solver.timer "inity" if !iszero(p)
        rhs = -model.c - G' * point.z
        if solver.init_use_iterative
            # use iterative solvers method TODO pick lsqr or lsmr
            point.y = zeros(T, p)
            IterativeSolvers.lsqr!(point.y, A', rhs)
        else
            if issparse(A) && !(T <: sparse_QR_reals)
                # TODO alternative fallback is to convert sparse{T} to sparse{Float64} and do the sparse LU
                if solver.init_use_fallback
                    @warn("using dense factorization of A' in initial point finding because sparse factorization for number type $T is not supported by SparseArrays")
                    @timeit solver.timer "lsqrAp" Ap_fact = qr!(Matrix(A'))
                else
                    error("sparse factorization for number type $T is not supported by SparseArrays, so Hypatia cannot find an initial point")
                end
            else
                @timeit solver.timer "lsqrAp" Ap_fact = issparse(A) ? qr(sparse(A')) : qr!(Matrix(A'))
            end

            Ap_rank = get_rank_est(Ap_fact, solver.init_tol_qr)
            if Ap_rank < p
                @warn("some primal equalities appear to be dependent; try using preprocess = true")
            end

            point.y = Ap_fact \ rhs
        end
    end

    return point
end

# preprocess and get initial point
function preprocess_find_initial_point(solver::Solver{T}) where {T <: Real}
    orig_model = solver.orig_model
    c = copy(orig_model.c)
    A = copy(orig_model.A)
    b = copy(orig_model.b)
    G = copy(orig_model.G)
    n = length(c)
    p = length(b)
    q = orig_model.q
    point = solver.point

    # solve for x as least squares solution to Ax = b, Gx = h - s
    @timeit solver.timer "leastsqrx" if !iszero(n)
        # get pivoted QR # TODO when Julia has a unified QR interface, replace this
        AG = vcat(A, G)
        if issparse(AG) && !(T <: sparse_QR_reals)
            if solver.init_use_fallback
                @warn("using dense factorization of [A; G] in preprocessing and initial point finding because sparse factorization for number type $T is not supported by SparseArrays")
                AG = Matrix(AG)
            else
                error("sparse factorization for number type $T is not supported by SparseArrays, so Hypatia cannot preprocess and find an initial point")
            end
        end
        @timeit solver.timer "qrAG" AG_fact = issparse(AG) ? qr(AG, tol = solver.init_tol_qr) : qr(AG, Val(true))

        AG_rank = get_rank_est(AG_fact, solver.init_tol_qr)
        if AG_rank == n
            # no dual equalities to remove
            x_keep_idxs = 1:n
            point.x = AG_fact \ vcat(b, orig_model.h - point.s)
        else
            col_piv = (AG_fact isa QRPivoted{T, Matrix{T}}) ? AG_fact.p : AG_fact.pcol
            x_keep_idxs = col_piv[1:AG_rank]
            AG_R = UpperTriangular(AG_fact.R[1:AG_rank, 1:AG_rank])

            # TODO optimize all below
            c_sub = c[x_keep_idxs]
            yz_sub = AG_fact.Q * (Matrix{T}(I, p + q, AG_rank) * (AG_R' \ c_sub))
            if !(AG_fact isa QRPivoted{T, Matrix{T}})
                yz_sub = yz_sub[AG_fact.rpivinv]
            end
            residual = norm(AG' * yz_sub - c, Inf)
            if residual > solver.init_tol_qr
                solver.verbose && println("some dual equality constraints are inconsistent (residual $residual, tolerance $(solver.init_tol_qr))")
                solver.status = :DualInconsistent
                return point
            end
            solver.verbose && println("removed $(n - AG_rank) out of $n dual equality constraints")

            point.x = AG_R \ (Matrix{T}(I, AG_rank, p + q) * (AG_fact.Q' * vcat(b, orig_model.h - point.s)))

            c = c_sub
            A = A[:, x_keep_idxs]
            G = G[:, x_keep_idxs]
            n = AG_rank
        end
    else
        x_keep_idxs = Int[]
    end

    # solve for y as least squares solution to A'y = -c - G'z
    @timeit solver.timer "leastsqry" if !iszero(p)
        if issparse(A) && !(T <: sparse_QR_reals)
            if solver.init_use_fallback
                @warn("using dense factorization of A' in preprocessing and initial point finding because sparse factorization for number type $T is not supported by SparseArrays")
                Ap_fact = qr!(Matrix(A'), Val(true))
            else
                error("sparse factorization for number type $T is not supported by SparseArrays, so Hypatia cannot preprocess and find an initial point")
            end
        else
            @timeit solver.timer "qrAp" Ap_fact = issparse(A) ? qr(sparse(A'), tol = solver.init_tol_qr) : qr(A', Val(true))
        end

        Ap_rank = get_rank_est(Ap_fact, solver.init_tol_qr)

        Ap_R = UpperTriangular(Ap_fact.R[1:Ap_rank, 1:Ap_rank])
        col_piv = (Ap_fact isa QRPivoted{T, Matrix{T}}) ? Ap_fact.p : Ap_fact.pcol
        y_keep_idxs = col_piv[1:Ap_rank]
        Ap_Q = Ap_fact.Q

        # TODO optimize all below
        b_sub = b[y_keep_idxs]
        if Ap_rank < p
            # some dependent primal equalities, so check if they are consistent
            x_sub = Ap_Q * (Matrix{T}(I, n, Ap_rank) * (Ap_R' \ b_sub))
            if !(Ap_fact isa QRPivoted{T, Matrix{T}})
                x_sub = x_sub[Ap_fact.rpivinv]
            end
            residual = norm(A * x_sub - b, Inf)
            if residual > solver.init_tol_qr
                solver.verbose && println("some primal equality constraints are inconsistent (residual $residual, tolerance $(solver.init_tol_qr))")
                solver.status = :PrimalInconsistent
            end
            solver.verbose && println("removed $(p - Ap_rank) out of $p primal equality constraints")
        end

        point.y = Ap_R \ (Matrix{T}(I, Ap_rank, n) * (Ap_fact.Q' *  (-c - G' * point.z)))

        if !(Ap_fact isa QRPivoted{T, Matrix{T}})
            row_piv = Ap_fact.prow
            A = A[y_keep_idxs, row_piv]
            c = c[row_piv]
            G = G[:, row_piv]
            x_keep_idxs = x_keep_idxs[row_piv]
        else
            A = A[y_keep_idxs, :]
        end
        b = b_sub
        p = Ap_rank
        solver.Ap_R = Ap_R
        solver.Ap_Q = Ap_Q
    else
        y_keep_idxs = Int[]
        solver.Ap_R = UpperTriangular(zeros(T, 0, 0))
        solver.Ap_Q = I
    end

    solver.x_keep_idxs = x_keep_idxs
    solver.y_keep_idxs = y_keep_idxs
    solver.model = Models.Model{T}(c, A, b, G, orig_model.h, orig_model.cones, obj_offset = orig_model.obj_offset)

    return point
end

function calc_mu(solver::Solver{T}) where {T <: Real}
    solver.mu = (dot(solver.point.z, solver.point.s) + solver.tau * solver.kap) /
        (one(T) + solver.model.nu)
    return solver.mu
end

# NOTE (pivoted) QR factorizations are usually rank-revealing but may be unreliable, see http://www.math.sjsu.edu/~foster/rankrevealingcode.html
# TODO could replace this with rank(Ap_fact) when available for both dense and sparse
function get_rank_est(qr_fact, init_tol_qr::Real)
    R = qr_fact.R
    rank_est = 0
    for i in 1:size(R, 1) # TODO could replace this with rank(AG_fact) when available for both dense and sparse
        if abs(R[i, i]) > init_tol_qr
            rank_est += 1
        end
    end
    return rank_est
end

function calc_residual(solver::Solver{T}) where {T <: Real}
    model = solver.model
    point = solver.point

    # x_residual = -A'*y - G'*z - c*tau
    x_residual = solver.x_residual
    mul!(x_residual, model.G', point.z)
    mul!(x_residual, model.A', point.y, true, true)
    solver.x_norm_res_t = norm(x_residual)
    @. x_residual += model.c * solver.tau
    solver.x_norm_res = norm(x_residual) / solver.tau
    @. x_residual *= -1

    # y_residual = A*x - b*tau
    y_residual = solver.y_residual
    mul!(y_residual, model.A, point.x)
    solver.y_norm_res_t = norm(y_residual)
    @. y_residual -= model.b * solver.tau
    solver.y_norm_res = norm(y_residual) / solver.tau

    # z_residual = s + G*x - h*tau
    z_residual = solver.z_residual
    mul!(z_residual, model.G, point.x)
    @. z_residual += point.s
    solver.z_norm_res_t = norm(z_residual)
    @. z_residual -= model.h * solver.tau
    solver.z_norm_res = norm(z_residual) / solver.tau

    return
end

function calc_convergence_params(solver::Solver{T}) where {T <: Real}
    model = solver.model
    point = solver.point

    solver.prev_gap = solver.gap
    solver.prev_rel_gap = solver.rel_gap
    solver.prev_x_feas = solver.x_feas
    solver.prev_y_feas = solver.y_feas
    solver.prev_z_feas = solver.z_feas

    solver.primal_obj_t = dot(model.c, point.x)
    solver.dual_obj_t = -dot(model.b, point.y) - dot(model.h, point.z)
    solver.primal_obj = solver.primal_obj_t / solver.tau + model.obj_offset
    solver.dual_obj = solver.dual_obj_t / solver.tau + model.obj_offset
    solver.gap = dot(point.z, point.s)
    if solver.primal_obj < zero(T)
        solver.rel_gap = solver.gap / -solver.primal_obj
    elseif solver.dual_obj > zero(T)
        solver.rel_gap = solver.gap / solver.dual_obj
    else
        solver.rel_gap = NaN
    end

    solver.x_feas = solver.x_norm_res * solver.x_conv_tol
    solver.y_feas = solver.y_norm_res * solver.y_conv_tol
    solver.z_feas = solver.z_norm_res * solver.z_conv_tol

    return
end

function print_iteration_stats(solver::Solver{T}) where {T <: Real}
    if iszero(solver.num_iters)
        @printf("\n%5s %12s %12s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s\n",
            "iter", "p_obj", "d_obj", "abs_gap", "rel_gap",
            "x_feas", "y_feas", "z_feas", "tau", "kap", "mu",
            "gamma", "alpha",
            )
        @printf("%5d %12.4e %12.4e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e\n",
            solver.num_iters, solver.primal_obj, solver.dual_obj, solver.gap, solver.rel_gap,
            solver.x_feas, solver.y_feas, solver.z_feas, solver.tau, solver.kap, solver.mu
            )
    else
        @printf("%5d %12.4e %12.4e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e %9.2e\n",
            solver.num_iters, solver.primal_obj, solver.dual_obj, solver.gap, solver.rel_gap,
            solver.x_feas, solver.y_feas, solver.z_feas, solver.tau, solver.kap, solver.mu,
            solver.prev_gamma, solver.prev_alpha,
            )
    end
    flush(stdout)
    return
end

function check_convergence(solver::Solver{T}) where {T <: Real}
    # check convergence criteria
    # TODO nearly primal or dual infeasible or nearly optimal cases?
    if max(solver.x_feas, solver.y_feas, solver.z_feas) <= solver.tol_feas &&
        (solver.gap <= solver.tol_abs_opt || (!isnan(solver.rel_gap) && solver.rel_gap <= solver.tol_rel_opt))
        solver.verbose && println("optimal solution found; terminating")
        solver.status = :Optimal
        return true
    end
    if solver.dual_obj_t > zero(T)
        infres_pr = solver.x_norm_res_t * solver.x_conv_tol / solver.dual_obj_t
        if infres_pr <= solver.tol_feas
            solver.verbose && println("primal infeasibility detected; terminating")
            solver.status = :PrimalInfeasible
            return true
        end
    end
    if solver.primal_obj_t < zero(T)
        infres_du = -max(solver.y_norm_res_t * solver.y_conv_tol, solver.z_norm_res_t * solver.z_conv_tol) / solver.primal_obj_t
        if infres_du <= solver.tol_feas
            solver.verbose && println("dual infeasibility detected; terminating")
            solver.status = :DualInfeasible
            return true
        end
    end
    if solver.mu <= solver.tol_feas * T(1e-2) && solver.tau <= solver.tol_feas * T(1e-2) * min(one(T), solver.kap)
        solver.verbose && println("ill-posedness detected; terminating")
        solver.status = :IllPosed
        return true
    end

    max_improve = zero(T)
    for (curr, prev) in ((solver.gap, solver.prev_gap), (solver.rel_gap, solver.prev_rel_gap),
        (solver.x_feas, solver.prev_x_feas), (solver.y_feas, solver.prev_y_feas), (solver.z_feas, solver.prev_z_feas))
        if isnan(prev) || isnan(curr)
            continue
        end
        max_improve = max(max_improve, (prev - curr) / (abs(prev) + eps(T)))
    end
    if max_improve < solver.tol_slow
        if solver.prev_is_slow && solver.prev2_is_slow
            solver.verbose && println("slow progress in consecutive iterations; terminating")
            solver.status = :SlowProgress
            return true
        else
            solver.prev2_is_slow = solver.prev_is_slow
            solver.prev_is_slow = true
        end
    else
        solver.prev2_is_slow = solver.prev_is_slow
        solver.prev_is_slow = false
    end

    return false
end

function step(solver::Solver{T}) where {T <: Real}
    model = solver.model
    point = solver.point

    # calculate affine/prediction and correction directions
    @timeit solver.timer "directions" (x_pred, x_corr, y_pred, y_corr, z_pred, z_corr, s_pred, s_corr, tau_pred, tau_corr, kap_pred, kap_corr) = get_combined_directions(solver.system_solver)

    # calculate correction factor gamma by finding distance aff_alpha for stepping in affine direction
    # TODO try setting nbhd to T(Inf) and avoiding the neighborhood checks - requires tuning
    @timeit solver.timer "aff_alpha" aff_alpha = find_max_alpha_in_nbhd(z_pred, s_pred, tau_pred, kap_pred, solver, nbhd = one(T), prev_alpha = max(solver.prev_aff_alpha, T(2e-2)), min_alpha = T(2e-2))
    solver.prev_aff_alpha = aff_alpha

    gamma = abs2(one(T) - aff_alpha) # TODO allow different function (heuristic)
    solver.prev_gamma = gamma

    # find distance alpha for stepping in combined direction
    z_comb = z_pred
    s_comb = s_pred
    pred_factor = one(T) - gamma
    @. z_comb = pred_factor * z_pred + gamma * z_corr
    @. s_comb = pred_factor * s_pred + gamma * s_corr
    tau_comb = pred_factor * tau_pred + gamma * tau_corr
    kap_comb = pred_factor * kap_pred + gamma * kap_corr
    @timeit solver.timer "comb_alpha" alpha = find_max_alpha_in_nbhd(z_comb, s_comb, tau_comb, kap_comb, solver, nbhd = solver.max_nbhd, prev_alpha = solver.prev_alpha, min_alpha = T(1e-2))

    if iszero(alpha)
        # could not step far in combined direction, so perform a pure correction step
        solver.verbose && println("performing correction step")
        z_comb = z_corr
        s_comb = s_corr
        tau_comb = tau_corr
        kap_comb = kap_corr
        @timeit solver.timer "corr_alpha" alpha = find_max_alpha_in_nbhd(z_comb, s_comb, tau_comb, kap_comb, solver, nbhd = solver.max_nbhd, prev_alpha = one(T), min_alpha = T(1e-6))

        if iszero(alpha)
            @warn("numerical failure: could not step in correction direction; terminating")
            solver.status = :NumericalFailure
            solver.keep_iterating = false
            return point
        end
        @. point.x += alpha * x_corr
        @. point.y += alpha * y_corr
    else
        @. point.x += alpha * (pred_factor * x_pred + gamma * x_corr)
        @. point.y += alpha * (pred_factor * y_pred + gamma * y_corr)
    end
    solver.prev_alpha = alpha

    # step distance alpha in combined direction
    @. point.z += alpha * z_comb
    @. point.s += alpha * s_comb
    solver.tau += alpha * tau_comb
    solver.kap += alpha * kap_comb
    calc_mu(solver)

    if solver.tau <= zero(T) || solver.kap <= zero(T) || solver.mu <= zero(T)
        @warn("numerical failure: tau is $(solver.tau), kappa is $(solver.kap), mu is $(solver.mu); terminating")
        solver.status = :NumericalFailure
        solver.keep_iterating = false
    end

    return point
end

# backtracking line search to find large distance to step in direction while remaining inside cones and inside a given neighborhood
function find_max_alpha_in_nbhd(
    z_dir::AbstractVector{T},
    s_dir::AbstractVector{T},
    tau_dir::T,
    kap_dir::T,
    solver::Solver{T};
    nbhd::T,
    prev_alpha::T,
    min_alpha::T,
    ) where {T <: Real}
    point = solver.point
    model = solver.model
    z_temp = solver.z_temp
    s_temp = solver.s_temp

    alpha = min(prev_alpha * T(1.4), one(T)) # TODO option for parameter
    if kap_dir < zero(T)
        alpha = min(alpha, -solver.kap / kap_dir)
    end
    if tau_dir < zero(T)
        alpha = min(alpha, -solver.tau / tau_dir)
    end
    alpha *= T(0.9999)

    solver.cones_infeas .= true
    tau_temp = kap_temp = taukap_temp = mu_temp = zero(T)
    while true
        @timeit solver.timer "ls_update" begin
        @. z_temp = point.z + alpha * z_dir
        @. s_temp = point.s + alpha * s_dir
        tau_temp = solver.tau + alpha * tau_dir
        kap_temp = solver.kap + alpha * kap_dir
        taukap_temp = tau_temp * kap_temp
        mu_temp = (dot(s_temp, z_temp) + taukap_temp) / (one(T) + model.nu)
        end

        if mu_temp > zero(T)
            @timeit solver.timer "nbhd_check" in_nbhd = check_nbhd(mu_temp, taukap_temp, nbhd, solver)
            if in_nbhd
                break
            end
        end

        if alpha < min_alpha
            # alpha is very small so finish
            alpha = zero(T)
            break
        end

        # iterate is outside the neighborhood: decrease alpha
        alpha *= T(0.8) # TODO option for parameter
    end

    return alpha
end

function check_nbhd(
    mu_temp::T,
    taukap_temp::T,
    nbhd::T,
    solver::Solver{T},
    ) where {T <: Real}
    cones = solver.model.cones
    sqrtmu = sqrt(mu_temp)

    rhs_nbhd = mu_temp * abs2(nbhd)
    lhs_nbhd = abs2(taukap_temp / sqrtmu - sqrtmu)
    if lhs_nbhd >= rhs_nbhd
        return false
    end

    Cones.load_point.(cones, solver.primal_views, sqrtmu)

    # accept primal iterate if it is inside the cone and neighborhood
    # first check inside cone for whichever cones were violated last line search iteration
    for (k, cone_k) in enumerate(cones)
        if solver.cones_infeas[k]
            Cones.reset_data(cone_k)
            if Cones.is_feas(cone_k)
                solver.cones_infeas[k] = false
                solver.cones_loaded[k] = true
            else
                return false
            end
        else
            solver.cones_loaded[k] = false
        end
    end

    for (k, cone_k) in enumerate(cones)
        if !solver.cones_loaded[k]
            Cones.reset_data(cone_k)
            if !Cones.is_feas(cone_k)
                return false
            end
        end

        # modifies dual_views
        duals_k = solver.dual_views[k]
        g_k = Cones.grad(cone_k)
        @. duals_k += g_k * sqrtmu

        if solver.use_infty_nbhd
            k_nbhd = abs2(norm(duals_k, Inf) / norm(g_k, Inf))
            # k_nbhd = abs2(maximum(abs(dj) / abs(gj) for (dj, gj) in zip(duals_k, g_k))) # TODO try this neighborhood
            lhs_nbhd = max(lhs_nbhd, k_nbhd)
        else
            nbhd_temp_k = solver.nbhd_temp[k]
            Cones.inv_hess_prod!(nbhd_temp_k, duals_k, cone_k)
            k_nbhd = dot(duals_k, nbhd_temp_k)
            if k_nbhd <= -cbrt(eps(T))
                @warn("numerical failure: cone neighborhood is $k_nbhd")
                return false
            elseif k_nbhd > zero(T)
                lhs_nbhd += k_nbhd
            end
        end

        if lhs_nbhd > rhs_nbhd
            return false
        end
    end

    return true
end
