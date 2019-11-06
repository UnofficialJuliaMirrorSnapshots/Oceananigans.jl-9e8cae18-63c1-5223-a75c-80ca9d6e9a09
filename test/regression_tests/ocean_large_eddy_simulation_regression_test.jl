using Oceananigans.TurbulenceClosures: VerstappenAnisotropicMinimumDissipation

interior(a, grid) = view(a, grid.Hx+1:grid.Nx+grid.Hx,
                            grid.Hy+1:grid.Ny+grid.Hy,
                            grid.Hz+1:grid.Nz+grid.Hz)

function get_fields_from_checkpoint(filename)
    file = jldopen(filename)

    solution = (
        u = file["velocities/u"],
        v = file["velocities/v"],
        w = file["velocities/w"],
        T = file["tracers/T"],
        S = file["tracers/S"]
    )

    Gⁿ = (
        u = file["timestepper/Gⁿ/u"],
        v = file["timestepper/Gⁿ/v"],
        w = file["timestepper/Gⁿ/w"],
        T = file["timestepper/Gⁿ/T"],
        S = file["timestepper/Gⁿ/S"]
    )

    G⁻ = (
        u = file["timestepper/G⁻/u"],
        v = file["timestepper/G⁻/v"],
        w = file["timestepper/G⁻/w"],
        T = file["timestepper/G⁻/T"],
        S = file["timestepper/G⁻/S"]
    )

    close(file)

    return solution, Gⁿ, G⁻
end

function run_ocean_large_eddy_simulation_regression_test(arch, closure)
    name = "ocean_large_eddy_simulation_" * string(typeof(closure).name.wrapper)

    spinup_steps = 10000
      test_steps = 10
              Δt = 2.0

    # Parameters
      Qᵀ = 5e-5     # Temperature flux at surface
      Qᵘ = -2e-5    # Velocity flux at surface
    ∂T∂z = 0.005    # Initial vertical temperature gradient

    # Boundary conditions
    u_bcs = HorizontallyPeriodicBCs(    top = BoundaryCondition(Flux, Qᵘ)       )
    T_bcs = HorizontallyPeriodicBCs(    top = BoundaryCondition(Flux, Qᵀ),
                                     bottom = BoundaryCondition(Gradient, ∂T∂z) )
    S_bcs = HorizontallyPeriodicBCs(    top = BoundaryCondition(Flux, 5e-8)     )

    # Model instantiation
    model = Model(
             architecture = arch,
                 grid = RegularCartesianGrid(size=(16, 16, 16), length=(16, 16, 16)),
                 coriolis = FPlane(f=1e-4),
                 buoyancy = SeawaterBuoyancy(equation_of_state=LinearEquationOfState(α=2e-4, β=8e-4)),
                  closure = closure,
      boundary_conditions = BoundaryConditions(u=u_bcs, T=T_bcs, S=S_bcs)
    )

    # The type of the underlying data, not the offset array.
    ArrayType = typeof(model.velocities.u.data.parent)

    ####
    #### Uncomment the block below to generate regression data.
    ####

    #=
    @warn ("You are generating new data for the ocean LES regression test.")

    # Initialize model: random noise damped at top and bottom
    Ξ(z) = randn() * z / model.grid.Lz * (1 + z / model.grid.Lz) # noise
    T₀(x, y, z) = 20 + ∂T∂z * z + ∂T∂z * model.grid.Lz * 1e-2 * Ξ(z)
    u₀(x, y, z) = sqrt(abs(Qᵘ)) * 1e-3 * Ξ(z)
    set!(model, u=u₀, w=u₀, T=T₀, S=35)

    time_step!(model, spinup_steps-test_steps, Δt)

    checkpointer = Checkpointer(model; frequency = test_steps, prefix = name * "_",
                                       dir = joinpath(dirname(@__FILE__), "data"))
    model.output_writers[:checkpointer] = checkpointer

    time_step!(model, 2test_steps, Δt)
    pop!(model.output_writers, :checkpointer)
    =#

    ####
    #### Regression test
    ####

    initial_filename = joinpath(dirname(@__FILE__), "data", name * "_$spinup_steps.jld2")

    solution₀, Gⁿ₀, G⁻₀ = get_fields_from_checkpoint(initial_filename)

    model.velocities.u.data.parent .= ArrayType(solution₀.u)
    model.velocities.v.data.parent .= ArrayType(solution₀.v)
    model.velocities.w.data.parent .= ArrayType(solution₀.w)
    model.tracers.T.data.parent    .= ArrayType(solution₀.T)
    model.tracers.S.data.parent    .= ArrayType(solution₀.S)

    model.timestepper.Gⁿ.u.data.parent .= ArrayType(Gⁿ₀.u)
    model.timestepper.Gⁿ.v.data.parent .= ArrayType(Gⁿ₀.v)
    model.timestepper.Gⁿ.w.data.parent .= ArrayType(Gⁿ₀.w)
    model.timestepper.Gⁿ.T.data.parent .= ArrayType(Gⁿ₀.T)
    model.timestepper.Gⁿ.S.data.parent .= ArrayType(Gⁿ₀.S)

    model.timestepper.G⁻.u.data.parent .= ArrayType(G⁻₀.u)
    model.timestepper.G⁻.v.data.parent .= ArrayType(G⁻₀.v)
    model.timestepper.G⁻.w.data.parent .= ArrayType(G⁻₀.w)
    model.timestepper.G⁻.T.data.parent .= ArrayType(G⁻₀.T)
    model.timestepper.G⁻.S.data.parent .= ArrayType(G⁻₀.S)

    model.clock.time = spinup_steps * Δt
    model.clock.iteration = spinup_steps

    time_step!(model, test_steps, Δt; init_with_euler=false)

    final_filename = joinpath(dirname(@__FILE__), "data", name * "_$(spinup_steps+test_steps).jld2")

    solution₁, Gⁿ₁, G⁻₁ = get_fields_from_checkpoint(final_filename)

    field_names = ["u", "v", "w", "T", "S"]
    fields = [model.velocities.u.data.parent, model.velocities.v.data.parent,
              model.velocities.w.data.parent, model.tracers.T.data.parent,
              model.tracers.S.data.parent]
    fields_correct = [solution₁.u, solution₁.v, solution₁.w,
                      solution₁.T, solution₁.S]
    summarize_regression_test(field_names, fields, fields_correct)

    @test all(Array(interior(solution₁.u, model.grid)) .≈ Array(interior(model.velocities.u)))
    @test all(Array(interior(solution₁.v, model.grid)) .≈ Array(interior(model.velocities.v)))
    @test all(Array(interior(solution₁.w, model.grid)) .≈ Array(interior(model.velocities.w)))
    @test all(Array(interior(solution₁.T, model.grid)) .≈ Array(interior(model.tracers.T)))
    @test all(Array(interior(solution₁.S, model.grid)) .≈ Array(interior(model.tracers.S)))

    return nothing
end
