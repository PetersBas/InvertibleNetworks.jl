# Affine scaling layer
# Author: Philipp Witte, pwitte3@gatech.edu
# Date: January 2020
#

export AffineLayer

"""
    AL = AffineLayer(nx, ny, nc; logdet=false)

 Create a layer for an affine transformation.

 *Input*:

 - `nx`, `ny, `nc`: input dimensions and number of channels

 - `logdet`: bool to indicate whether to compute the logdet

 *Output*:

 - `AL`: Network layer for affine transformation.

 *Usage:*

 - Forward mode: `Y, logdet = AL.forward(X)`

 - Inverse mode: `X = AL.inverse(Y)`

 - Backward mode: `ΔX, X = AL.backward(ΔY, Y)`

 *Trainable parameters:*

 - Scaling factor `AL.s`

 - Bias `AL.b`

 See also: [`get_params`](@ref), [`clear_grad!`](@ref)
"""
struct AffineLayer <: NeuralNetLayer
    s::Parameter
    b::Parameter
    logdet::Bool
end

@Flux.functor AffineLayer

# Constructor: Initialize with nothing
function AffineLayer(nx::Int64, ny::Int64, nc::Int64; logdet=false)
    s = Parameter(glorot_uniform(nx, ny, nc))
    b = Parameter(zeros(Float32, nx, ny, nc))
    return AffineLayer(s, b, logdet)
end

# Foward pass: Input X, Output Y
function forward(X, AL::AffineLayer)

    Y = X .* AL.s.data .+ AL.b.data

    # If logdet true, return as second ouput argument
    AL.logdet == true ? (return Y, logdet_forward(AL.s)) : (return Y)
end

# Inverse pass: Input Y, Output X
function inverse(Y, AL::AffineLayer; eps::Float32=0f0)
    X = (Y .- AL.b.data) ./ (AL.s.data .+ eps)   # avoid division by 0
    return X
end

# Backward pass: Input (ΔY, Y), Output (ΔY, Y)
function backward(ΔY, Y, AL::AffineLayer; set_grad::Bool=true)
    nx, ny, n_in, batchsize = size(Y)
    X = inverse(Y, AL)
    ΔX = ΔY .* AL.s.data
    Δs = sum(ΔY .* X, dims=4)[:,:,:,1]
    if AL.logdet
        set_grad ? (Δs -= logdet_backward(AL.s)) : (Δs_ = logdet_backward(AL.s))
    end
    Δb = sum(ΔY, dims=4)[:,:,:,1]
    if set_grad
        AL.s.grad = Δs
        AL.b.grad = Δb
    else
        Δθ = [Parameter(Δs), Parameter(Δb)]
    end
    if set_grad
        return ΔX, X
    else
        AL.logdet ? (return ΔX, Δθ, X, [Parameter(Δs_), Parameter(0f0.*Δb)]) : (return ΔX, Δθ, X)
    end
end


## Jacobian-related utils

function jacobian(ΔX, Δθ, X, AL::AffineLayer)
    Y = X .* AL.s.data .+ AL.b.data
    ΔY = ΔX .* AL.s.data + X .* Δθ[1].data .+ Δθ[2].data
    if AL.logdet
        return ΔY, Y, logdet_forward(AL.s), [Parameter(logdet_hessian(AL.s).*Δθ[1].data), 0f0*Δθ[2]]
    else
        return ΔY, Y
    end
end

adjointJacobian(ΔY, Y, AL::AffineLayer) = backward(ΔY, Y, AL; set_grad=false)


## Other utils

# Clear gradients
function clear_grad!(AL::AffineLayer)
    AL.s.grad = nothing
    AL.b.grad = nothing
end

# Get parameters
get_params(AL::AffineLayer) = [AL.s, AL.b]

# Put parameters
function put_params!(AL::AffineLayer, Params::Array{Any,1})
    AL.s.data = Params[1].data
    AL.b.data = Params[2].data
end

# Logdet
logdet_forward(s) = sum(log.(abs.(s.data)))
logdet_backward(s) = 1f0 ./ s.data
logdet_hessian(s) = -1f0 ./ s.data.^2f0
