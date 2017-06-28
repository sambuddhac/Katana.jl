
"""
docs go here
"""
type KatanaNonlinearModel <: MathProgBase.AbstractNonlinearModel
    lp_solver    :: MathProgBase.AbstractMathProgSolver
    linear_model :: Union{Void,JuMP.Model}
    nlp_eval     :: MathProgBase.AbstractNLPEvaluator
    status       :: Symbol
    objval       :: Float64
    f_tol        :: Float64 # feasibility tolerance
    nconstr   :: Int64 # number of NL constraints
    dim          :: Int64 # number of variables

    function KatanaNonlinearModel(lps::MathProgBase.AbstractMathProgSolver)
        katana = new() # don't initialise everything yet
        katana.lp_solver = lps
        katana.status = :None
        katana.objval = NaN
        katana.f_tol = 1e-6
        return katana
    end
end

type SparseCol
    col :: Int # column index in Jacobian
    ind :: Int # original index in sparse Jacobian vector
end

function MathProgBase.NonlinearModel(s::KatanaSolver)
    return KatanaNonlinearModel(s.lp_solver)
end


function MathProgBase.loadproblem!(
    m::KatanaNonlinearModel,
    num_var::Int, num_constr::Int,
    l_var::Vector{Float64}, u_var::Vector{Float64},
    l_constr::Vector{Float64}, u_constr::Vector{Float64},
    sense::Symbol, d::MathProgBase.AbstractNLPEvaluator)

    MathProgBase.initialize(d, [:Grad,:Jac,:Hess,:ExprGraph])

    # setup the internal LP model
    m.linear_model = Model(solver=m.lp_solver)

    # distinguish between internal LP model and external NLP model
    outer_nlpmod = d.m
    inner_lpmod = m.linear_model

    # initialise other fields of the KatanaNonlinearModel
    m.nlp_eval = d # need this later for operations on the jacobian
    m.dim = num_var
    m.nconstr = MathProgBase.numconstr(outer_nlpmod)

    # add variables
    inner_lpmod.numCols = outer_nlpmod.numCols
    inner_lpmod.objDict = Dict{Symbol, Any}()
    for (key,val) in outer_nlpmod.objDict # deep copy objdict
        var = JuMP.Variable(inner_lpmod, val.col)
        JuMP.registervar(inner_lpmod, key, var)
    end
    inner_lpmod.colNames = outer_nlpmod.colNames
    inner_lpmod.colNamesIJulia = outer_nlpmod.colNamesIJulia
    inner_lpmod.colLower = outer_nlpmod.colLower
    inner_lpmod.colUpper = outer_nlpmod.colUpper
    inner_lpmod.colCat = outer_nlpmod.colCat
    inner_lpmod.colVal = outer_nlpmod.colVal

    # by convention, "x" variables can be the original variables and 
    # "y" variables can be auxiliary variables
    # a convention along these lines will help with filtering later

    if MathProgBase.isobjlinear(d)
        # add to model
        println("objective is linear")
        obj = copy(outer_nlpmod.obj, inner_lpmod) # copy variables over to linear model
        JuMP.setobjective(inner_lpmod, sense, obj)
    else
        if MathProgBase.isobjquadratic(d) && False # (add check if m.lp_solver can support quadratic obj)
            # add to model
        else
            # add aux variable for objective and add to model
            println("objective is nonlinear")
        end
    end

    for constr in outer_nlpmod.linconstr
        newconstr = copy(constr, inner_lpmod) # copy constraint
        JuMP.addconstraint(inner_lpmod, newconstr)
    end
end



function MathProgBase.optimize!(m::KatanaNonlinearModel)
    # fixpoint algorithm:
    # 1. run LP solver to compute x*
    # 2. for every unsatisfied non-linear constraint (±f_tol):
    #   3. add first-order cut
    # 4. check convergence (|g(x) - c| <= f_tol for all g) 

    status = :NotSolved
    sp_rows, sp_cols = MathProgBase.jac_structure(m.nlp_eval)
    sp_by_row = Vector{SparseCol}[ [] for i=1:m.nconstr] # map a row to vector of nonzero columns' indices
    N = 0 # number of sparse entries
    for ind in 1:length(sp_rows)
        i,j = sp_rows[ind],sp_cols[ind]
        push!(sp_by_row[i], SparseCol(j,ind)) # column j is nonzero in row i
        N += 1
    end

    J = zeros(N) # Jacobian of constraint functions
    g = zeros(m.nconstr) # constraint values
    allsat = false
    iter = 0
    while !allsat # placeholder condition
        iter += 1
        status = solve(m.linear_model)
        if status == :Unbounded
          # run bounding routine
        elseif status != :Optimal break end

        xstar = MathProgBase.getsolution(internalmodel(m.linear_model))
        MathProgBase.eval_jac_g(m.nlp_eval, J, xstar) # hopefully variable ordering is consistent with MPB
        MathProgBase.eval_g(m.nlp_eval, g, xstar) # evaluate constraints
        allsat = true # base case
        for i=1:m.nconstr
            if !MathProgBase.isconstrlinear(m.nlp_eval,i) # is there a better way to iterate over NL constraints?
                constr = MathProgBase.constr_expr(m.nlp_eval, i)
                sat = false # is this constraint satisfied?
                l = length(constr.args)
                @assert l == 3 || l == 5 # sane assumption?
                if l == 3 # one-sided constraint
                    constr.args[2] = g[i] # evaluated constraint

                    # here we determine if the constraint is a > or >= to add f_tol,
                    #  or <, <= to subtract f_tol (if it's equality, it doesn't matter)
                    op = eval(Expr(constr.head, constr.args[1], 1.0, 0.0)) ? (-) : (+)
                    constr.args[3] = op(constr.args[3], m.f_tol) # add tolerance to bound
                else
                   constr.args[3] = g[i]

                   # must be in the form lb <= constr <= ub, so we incorporate f_tol
                   constr.args[1] -= m.f_tol
                   constr.args[5] += m.f_tol
                end
                if !(sat = eval(constr)) # if constraint not satisfied, add Taylor cut
                    # construct the affine expression from sparse gradient:
                    #  g'(x) = g_i(x*) + (x-x*) ⋅ ∇g_i(x*)
                    v = Vector{JuMP.Variable}()
                    coefs = Vector{Float64}()
                    b = g[i]
                    inner_model = m.linear_model
                    for spc in sp_by_row[i]
                        # lookup JuMP variable from column index:
                        var = inner_model.objDict[parse(inner_model.colNames[spc.col])]
                        push!(v,var)
                        partial = J[spc.ind]
                        push!(coefs, partial)
                        b += -xstar[spc.col]*partial
                    end
                    newconstr = LinearConstraint(AffExpr(v, coefs, 0.0), -Inf, -b)
                    JuMP.addconstraint(inner_model, newconstr) # add this cut to the LP
                end

                allsat &= sat # loop condition: each constraint must be satisfied
            end
        end
    end

    println("Katana convergence in $iter iterations.")

    assert(status == :Optimal)
    m.status = status
    return m.status
end


function MathProgBase.setwarmstart!(m::KatanaNonlinearModel, x)
    #TODO, not clear what we can do with x, ignore for now
end

MathProgBase.status(m::KatanaNonlinearModel) = m.status
MathProgBase.getobjval(m::KatanaNonlinearModel) = getobjectivevalue(m.linear_model)

# any auxiliary variables will need to be filtered from this at some point
MathProgBase.getsolution(m::KatanaNonlinearModel) = MathProgBase.getsolution(internalmodel(m.linear_model))


