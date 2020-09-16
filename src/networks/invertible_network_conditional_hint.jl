# Invertible conditional HINT network from Kruse et. al (2020)
# Author: Philipp Witte, pwitte3@gatech.edu
# Date: February 2020

export NetworkConditionalHINT

"""
    CH = NetworkConditionalHINT(nx, ny, n_in, batchsize, n_hidden, depth; k1=3, k2=3, p1=1, p2=1, s1=1, s2=1)

 Create a conditional HINT network for data-driven generative modeling based
 on the change of variables formula.

 *Input*:

 - `nx`, `ny`, `n_in`, `batchsize`: spatial dimensions, number of channels and batchsize of input tensors `X` and `Y`

 - `n_hidden`: number of hidden units in residual blocks

 - `depth`: number network layers

 - `k1`, `k2`: kernel size for first and third residual layer (`k1`) and second layer (`k2`)

 - `p1`, `p2`: respective padding sizes for residual block layers

 - `s1`, `s2`: respective strides for residual block layers

 *Output*:

 - `CH`: conditioinal HINT network

 *Usage:*

 - Forward mode: `Zx, Zy, logdet = CH.forward(X, Y)`

 - Inverse mode: `X, Y = CH.inverse(Zx, Zy)`

 - Backward mode: `ΔX, X = CH.backward(ΔZx, ΔZy, Zx, Zy)`

 *Trainable parameters:*

 - None in `CH` itself

 - Trainable parameters in activation normalizations `CH.AN_X[i]` and `CH.AN_Y[i]`,
 and in coupling layers `CH.CL[i]`, where `i` ranges from `1` to `depth`.

 See also: [`ActNorm`](@ref), [`ConditionalLayerHINT!`](@ref), [`get_params`](@ref), [`clear_grad!`](@ref)
"""
mutable struct NetworkConditionalHINT <: InvertibleNetwork
    AN_X::AbstractArray{ActNorm, 1}
    AN_Y::AbstractArray{ActNorm, 1}
    CL::AbstractArray{ConditionalLayerHINT, 1}
    logdet::Bool
    is_reversed::Bool
end

@Flux.functor NetworkConditionalHINT

# Constructor
function NetworkConditionalHINT(nx, ny, n_in, batchsize, n_hidden, depth; k1=3, k2=3, p1=1, p2=1, s1=1, s2=1, logdet=true)

    AN_X = Array{ActNorm}(undef, depth)
    AN_Y = Array{ActNorm}(undef, depth)
    CL = Array{ConditionalLayerHINT}(undef, depth)

    # Create layers
    for j=1:depth
        AN_X[j] = ActNorm(n_in; logdet=logdet)
        AN_Y[j] = ActNorm(n_in; logdet=logdet)
        CL[j] = ConditionalLayerHINT(nx, ny, n_in, n_hidden, batchsize;
                                     permute=true, k1=k1, k2=k2, p1=p1, p2=p2, s1=s1, s2=s2, logdet=logdet)
    end

    return NetworkConditionalHINT(AN_X, AN_Y, CL, logdet, false)
end

# Forward pass and compute logdet
function forward(X, Y, CH::NetworkConditionalHINT; logdet=nothing)
    isnothing(logdet) ? logdet = (CH.logdet && ~CH.is_reversed) : logdet = logdet

    depth = length(CH.CL)
    logdet_ = 0f0
    for j=1:depth
        logdet ? (X_, logdet1) = CH.AN_X[j].forward(X) : X_ = CH.AN_X[j].forward(X)
        logdet ? (Y_, logdet2) = CH.AN_Y[j].forward(Y) : Y_ = CH.AN_Y[j].forward(Y)
        logdet ? (X, Y, logdet3) = CH.CL[j].forward(X_, Y_) : (X, Y) = CH.CL[j].forward(X_, Y_)
        logdet && (logdet_ += (logdet1 + logdet2 + logdet3))
    end
    logdet ? (return X, Y, logdet_) : (return X, Y)
end

# Inverse pass and compute gradients
function inverse(Zx, Zy, CH::NetworkConditionalHINT; logdet=nothing)
    isnothing(logdet) ? logdet = (CH.logdet && CH.is_reversed) : logdet = logdet

    depth = length(CH.CL)
    logdet_ = 0f0
    for j=depth:-1:1
        logdet ? (Zx_, Zy_, logdet1) = CH.CL[j].inverse(Zx, Zy; logdet=true) : (Zx_, Zy_) = CH.CL[j].inverse(Zx, Zy; logdet=false)
        logdet ? (Zy, logdet2) = CH.AN_Y[j].inverse(Zy_; logdet=true) : Zy = CH.AN_Y[j].inverse(Zy_; logdet=false)
        logdet ? (Zx, logdet3) = CH.AN_X[j].inverse(Zx_; logdet=true) : Zx = CH.AN_X[j].inverse(Zx_; logdet=false)
        logdet && (logdet_ += (logdet1 + logdet2 + logdet3))
    end
    logdet ? (return Zx, Zy, logdet_) : (return Zx, Zy)
end

# Backward pass and compute gradients
function backward(ΔZx, ΔZy, Zx, Zy, CH::NetworkConditionalHINT)
    depth = length(CH.CL)
    for j=depth:-1:1
        ΔZx_, ΔZy_, Zx_, Zy_ = CH.CL[j].backward(ΔZx, ΔZy, Zx, Zy)
        ΔZx, Zx = CH.AN_X[j].backward(ΔZx_, Zx_)
        ΔZy, Zy = CH.AN_Y[j].backward(ΔZy_, Zy_)
    end
    return ΔZx, ΔZy, Zx, Zy
end

# Backward reverse pass and compute gradients
function backward_inv(ΔX, ΔY, X, Y, CH::NetworkConditionalHINT)
    depth = length(CH.CL)
    for j=1:depth
        ΔX_, X_ = backward_inv(ΔX, X, CH.AN_X[j])
        ΔY_, Y_ = backward_inv(ΔY, Y, CH.AN_Y[j])
        ΔX, ΔY, X, Y = backward_inv(ΔX_, ΔY_, X_, Y_, CH.CL[j])
    end
    return ΔX, ΔY, X, Y
end

# Forward pass and compute logdet
function forward_Y(Y, CH::NetworkConditionalHINT)
    depth = length(CH.CL)
    for j=1:depth
        Y_ = CH.AN_Y[j].forward(Y; logdet=false)
        Y = CH.CL[j].forward_Y(Y_)
    end
    return Y
end

# Inverse pass and compute gradients
function inverse_Y(Zy, CH::NetworkConditionalHINT)
    depth = length(CH.CL)
    for j=depth:-1:1
        Zy_ = CH.CL[j].inverse_Y(Zy)
        Zy = CH.AN_Y[j].inverse(Zy_; logdet=false)
    end
    return Zy
end

# Clear gradients
function clear_grad!(CH::NetworkConditionalHINT)
    depth = length(CH.CL)
    for j=1:depth
        clear_grad!(CH.AN_X[j])
        clear_grad!(CH.AN_Y[j])
        clear_grad!(CH.CL[j])
    end
end

# Get parameters
function get_params(CH::NetworkConditionalHINT)
    depth = length(CH.CL)
    p = []
    for j=1:depth
        p = cat(p, get_params(CH.AN_X[j]); dims=1)
        p = cat(p, get_params(CH.AN_Y[j]); dims=1)
        p = cat(p, get_params(CH.CL[j]); dims=1)
    end
    return p
end

# Put parameters
function put_params!(CH::NetworkConditionalHINT, Params::Array{Any,1})
    depth = length(CH.CL)
    idx_s = 1
    counter = 0

    for j = 1:depth
        idx_s += counter
        counter = 2
        put_params!(CH.AN_X[j], Params[idx_s:idx_s+counter-1])

        idx_s += counter
        counter = 2
        put_params!(CH.AN_Y[j], Params[idx_s:idx_s+counter-1])

        idx_s += counter
        counter = 0
        nlayers_x = length(CH.CL[j].CL_X.CL)
        isnothing(CH.CL[j].CL_X.C) ? counter += 5*nlayers_x : counter += 5*nlayers_x + 3
        nlayers_y = length(CH.CL[j].CL_Y.CL)
        isnothing(CH.CL[j].CL_Y.C) ? counter += 5*nlayers_y : counter += 5*nlayers_y + 3
        counter += 5
        ~isnothing(CH.CL[j].C_X) && (counter += 3)
        ~isnothing(CH.CL[j].C_Y) && (counter += 3)

        put_params!(CH.CL[j], Params[idx_s:idx_s+counter-1])
    end
end

# Set is_reversed flag in full network tree
function tag_as_reversed!(CH::NetworkConditionalHINT, tag::Bool)
    depth = length(CH.CL)
    CH.is_reversed = tag
    for j=1:depth
        tag_as_reversed!(CH.AN_X[j], tag)
        tag_as_reversed!(CH.AN_Y[j], tag)
        tag_as_reversed!(CH.CL[j], tag)
    end
    return CH
end
