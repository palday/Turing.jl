doc"""
    HMCDA(n_iters::Int, n_adapt::Int, delta::Float64, lambda::Float64)

Hamiltonian Monte Carlo sampler wiht Dual Averaging algorithm.

Usage:

```julia
HMCDA(1000, 200, 0.65, 0.3)
```

Example:

```julia
# Define a simple Normal model with unknown mean and variance.
@model gdemo(x) = begin
  s ~ InverseGamma(2,3)
  m ~ Normal(0,sqrt(s))
  x[1] ~ Normal(m, sqrt(s))
  x[2] ~ Normal(m, sqrt(s))
  return s, m
end

sample(gdemo([1.5, 2]), HMCDA(1000, 200, 0.65, 0.3))
```
"""
immutable HMCDA <: InferenceAlgorithm
  n_iters   ::  Int       # number of samples
  n_adapt   ::  Int       # number of samples with adaption for epsilon
  delta     ::  Float64   # target accept rate
  lambda    ::  Float64   # target leapfrog length
  space     ::  Set       # sampling space, emtpy means all
  gid       ::  Int       # group ID

  HMCDA(n_adapt::Int, delta::Float64, lambda::Float64, space...) = new(1, n_adapt, delta, lambda, isa(space, Symbol) ? Set([space]) : Set(space), 0)
  HMCDA(n_iters::Int, delta::Float64, lambda::Float64) = begin
    n_adapt_default = Int(round(n_iters / 5))
    new(n_iters, n_adapt_default > 1000 ? 1000 : n_adapt_default, delta, lambda, Set(), 0)
  end
  HMCDA(alg::HMCDA, new_gid::Int) =
    new(alg.n_iters, alg.n_adapt, alg.delta, alg.lambda, alg.space, new_gid)
  HMCDA(n_iters::Int, n_adapt::Int, delta::Float64, lambda::Float64) =
    new(n_iters, n_adapt, delta, lambda, Set(), 0)
  HMCDA(n_iters::Int, n_adapt::Int, delta::Float64, lambda::Float64, space...) =
    new(n_iters, n_adapt, delta, lambda, isa(space, Symbol) ? Set([space]) : Set(space), 0)
  HMCDA(n_iters::Int, n_adapt::Int, delta::Float64, lambda::Float64, space::Set, gid::Int) =
    new(n_iters, n_adapt, delta, lambda, space, gid)
end

function step(model, spl::Sampler{HMCDA}, vi::VarInfo, is_first::Bool)
  if is_first
    if spl.alg.gid != 0 link!(vi, spl) end      # X -> R

    spl.info[:θ_mean] = realpart(vi[spl])
    spl.info[:θ_num] = 1
    D = length(vi[spl])
    spl.info[:stds] = ones(D)
    spl.info[:θ_vars] = nothing

    if spl.alg.delta > 0
      ϵ = find_good_eps(model, vi, spl)           # heuristically find optimal ϵ
      # ϵ = 0.1
    else
      ϵ = spl.info[:ϵ][end]
    end

    if spl.alg.gid != 0 invlink!(vi, spl) end   # R -> X

    spl.info[:ϵ] = [ϵ]
    spl.info[:μ] = log(10 * ϵ)
    spl.info[:ϵ_bar] = 1.0
    spl.info[:H_bar] = 0.0
    spl.info[:m] = 0



    push!(spl.info[:accept_his], true)

    vi
  else
    # Set parameters
    δ = spl.alg.delta
    λ = spl.alg.lambda
    ϵ = spl.info[:ϵ][end]

    dprintln(2, "current ϵ: $ϵ")
    μ, γ, t_0, κ = spl.info[:μ], 0.05, 10, 0.75
    ϵ_bar, H_bar = spl.info[:ϵ_bar], spl.info[:H_bar]

    dprintln(3, "X-> R...")
    if spl.alg.gid != 0
      link!(vi, spl)
      runmodel(model, vi, spl)
    end

    dprintln(2, "sampling momentum...")
    p = sample_momentum(vi, spl)

    dprintln(2, "recording old values...")
    old_θ = vi[spl]; old_logp = getlogp(vi)
    old_H = find_H(p, model, vi, spl)

    τ = max(1, round(Int, λ / ϵ))
    dprintln(2, "leapfrog for $τ steps with step size $ϵ")
    θ, p, τ_valid = leapfrog2(old_θ, p, τ, ϵ, model, vi, spl)

    dprintln(2, "computing new H...")
    H = τ_valid == 0 ? Inf : find_H(p, model, vi, spl)

    dprintln(2, "computing accept rate α...")
    α = min(1, exp(-(H - old_H)))

    if ~(isdefined(Main, :IJulia) && Main.IJulia.inited) # Fix for Jupyter notebook.
    haskey(spl.info, :progress) && ProgressMeter.update!(
                                     spl.info[:progress],
                                     spl.info[:progress].counter; showvalues = [(:ϵ, ϵ), (:α, α), (:pre_cond, spl.info[:stds])]
                                   )
    end

    dprintln(2, "adapting step size ϵ...")
    m = spl.info[:m] += 1
    if m < spl.alg.n_adapt
      dprintln(1, " ϵ = $ϵ, α = $α")
      H_bar = (1 - 1 / (m + t_0)) * H_bar + 1 / (m + t_0) * (δ - α)
      ϵ = exp(μ - sqrt(m) / γ * H_bar)
      ϵ_bar = exp(m^(-κ) * log(ϵ) + (1 - m^(-κ)) * log(ϵ_bar))
      push!(spl.info[:ϵ], ϵ)
      spl.info[:ϵ_bar], spl.info[:H_bar] = ϵ_bar, H_bar
    elseif m == spl.alg.n_adapt
      dprintln(0, " Adapted ϵ = $ϵ, $m HMC iterations is used for adaption.")
      push!(spl.info[:ϵ], spl.info[:ϵ_bar])
    end

    dprintln(2, "decide wether to accept...")
    if rand() < α             # accepted
      push!(spl.info[:accept_his], true)
    else                      # rejected
      push!(spl.info[:accept_his], false)
      vi[spl] = old_θ         # reset Θ
      setlogp!(vi, old_logp)  # reset logp
    end

    θ_new = realpart(vi[spl])                                         # x_t
    spl.info[:θ_num] += 1
    t = spl.info[:θ_num]                                              # t
    θ_mean_old = copy(spl.info[:θ_mean])                              # x_bar_t-1
    spl.info[:θ_mean] = (t - 1) / t * spl.info[:θ_mean] + θ_new / t   # x_bar_t
    θ_mean_new = spl.info[:θ_mean]                                    # x_bar_t

    if t == 2
      first_two = [θ_mean_old'; θ_new'] # θ_mean_old here only contains the first θ
      spl.info[:θ_vars] = diag(cov(first_two))
    elseif t <= 1000
      # D = length(θ_new)
      D = 2.4^2
      spl.info[:θ_vars] = (t - 1) / t * spl.info[:θ_vars] .+ 100 * eps(Float64) +
                          (2.4^2 / D) / t * (t * θ_mean_old .* θ_mean_old - (t + 1) * θ_mean_new .* θ_mean_new + θ_new .* θ_new)
    end

    if t > 500
      spl.info[:stds] = sqrt(spl.info[:θ_vars])
      spl.info[:stds] = spl.info[:stds] / min(spl.info[:stds]...)
    end

    dprintln(3, "R -> X...")
    if spl.alg.gid != 0 invlink!(vi, spl); cleandual!(vi) end

    vi
  end
end
