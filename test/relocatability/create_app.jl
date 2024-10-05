using PackageCompiler

"""
    compile_to_app(; n_precompile_tasks::Int=4, kwargs...)

This function creates the app and stores all dependencies in a `sysimages/app` directory
Keyword arguments are forwarded to `create_app`.

If you have out of memory issues, probably the n_precompile_tasks option does not really work. 
Make sure you have set the environment variable JULIA_NUM_PRECOMPILE_TASKS to a low enough number in the shell which started the Julia application.
"""
function compile_to_app(; n_precompile_tasks::Int=4, kwargs...)

    # To avoid out of memory errors, see https://discourse.julialang.org/t/parallel-precompilation-and-out-of-memory-errors/98952
    # Probably not necessary to re-set the environment variable since this will not influence anything outside anyway...
    key = "JULIA_NUM_PRECOMPILE_TASKS"
    n_precompile_tasks_old = if haskey(ENV, key)
        ENV[key]
    else
        nothing
    end

    ENV[key]=n_precompile_tasks # let's hope this has any influence since the rest is actually called in an extra shell...
    create_app(
        "Compiling", # the folder where the source for this package is at; must be called from directory directly above!
        joinpath("app"); # destination for the created app
        executables=["timezones" => "main"], # creates an executable called 'timezones' which calls the `main` function
        force=true, # forces re-creation of the directory if it already exists
        include_lazy_artifacts=true, 
        kwargs...
    ) 
    !isnothing(n_precompile_tasks_old) && (ENV[key] = n_precompile_tasks_old)
end

compile_to_app()