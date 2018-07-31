using Base.Test

const mpb_tests = [
    "lp_01a",
    "lp_01b",
    "lp_02",
    "lp_03",
    "lp_04",
    "mip_01",
    "qp_01",
    "qp_02",
    "qcqp_01",
    "mathprog",
    "test_grb_attrs",
    "env",
    "range_constraints",
    "test_get_strarray",
    "large_coefficients",
    "multiobj",
    "test_read"
]

@testset "MathProgBase Tests" begin
    for t in mpb_tests
        fp = "$(t).jl"
        println("running $(fp) ...")
        evalfile(joinpath("MathProgBase", fp))
    end
end

@testset "MathOptInterface Tests" begin
    evalfile("MOIWrapper.jl")
end

include("constraint_modification.jl")

@testset "Empty constraints (Issue #142)" begin
    @testset "No variables, no constraints" begin
        model = Gurobi.Model(Gurobi.Env(), "model")
        A = Gurobi.get_constrmatrix(model)
        @test size(A) == (0, 0)
    end
    @testset "One variable, no constraints" begin
        model = Gurobi.Model(Gurobi.Env(), "model")
        Gurobi.add_cvar!(model, 0.0)
        Gurobi.update_model!(model)
        A = Gurobi.get_constrmatrix(model)
        @test size(A) == (0, 1)
    end
end
