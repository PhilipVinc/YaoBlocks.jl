using LinearAlgebra, YaoArrayRegister, YaoBase

export Roller, roll, rollrepeat

"""
    Roller{N, T, BT <: Tuple} <: CompositeBlock{N, T}

Roller block.
"""
struct Roller{N, T, BT <: Tuple} <: CompositeBlock{N, T}
    blocks::BT
    function Roller{N, T, BT}(blocks::BT) where {N, T, BT}
        sum(nqubits, blocks) == N || throw(AddressConflictError("Size of blocks does not match roller size."))
        new{N, T, BT}(blocks)
    end
end

Roller{T}(blocks::Tuple) where T = Roller{sum(nqubits, blocks), T, typeof(blocks)}(blocks)
Roller(blocks::Tuple) = Roller{blocks|>_blockpromote}(blocks)
Roller(blocks::AbstractBlock...) = Roller(blocks)
Roller{N}(block::MatrixBlock{K, T}) where {N, K, T} = Roller{N, T, NTuple{N÷K, typeof(block)}}(ntuple(x->deepcopy(block), Val(N÷K)))

rollrepeat(n::Int, block::MatrixBlock) = Roller{n}(block)
rollrepeat(block::MatrixBlock) = n->rollrepeat(n, block)

"""
    roll(n, blocks...)

Return a [`Roller`](@ref) with total number of active qubits.
"""
roll(n::Int, blocks...,) = roll(n, blocks)

function roll(n::Int, blocks::MatrixBlock...,)
    sum(nqubits, blocks) == n || throw(AddressConflictError("Size of blocks does not match total size."))
    Roller(blocks...,)
end

function roll(n::Int, a::Pair, blocks...,)
    roll(n, (a, blocks...,))
end

function roll(n::Int, itr)
    first(itr) isa Pair || throw(ArgumentError("Expect a Pair"))

    curr_head = 1
    list = []
    for each in itr
        if each isa MatrixBlock
            push!(list, each)
            curr_head += nqubits(each)
        elseif each isa Pair{Int, <:MatrixBlock}
            line, b = each
            k = line - curr_head

            k > 0 && push!(list, kron(k, i=>I2 for i=1:k))
            push!(list, b)
            curr_head = line + nqubits(b)
        end
    end

    k = n - curr_head + 1
    k > 0 && push!(list, kron(k, i=>I2 for i=1:k))

    sum(nqubits, list) == n || throw(ErrorException("number of qubits mismatch"))
    Roller(list...,)
end

roll(blocks...,) = @λ(n->roll(n, blocks...,))
roll(itr) = @λ(n->roll(n, itr))

subblocks(m::Roller) = m.blocks
mat(m::Roller) = mapreduce(mat, kron, reverse(m.blocks))

function apply!(reg::ArrayReg{1, T}, m::Roller{N}) where {N, T}
    st = vec(reg.state) # TODO: This is not type stable
    temp = Vector{T}(undef, 1 << (N - 1))
    for block in m.blocks
        K = nqubits(block)
        instruct!(st, mat(block), 1)
        rolldims!(Val(K), Val(N), Val(1), st, temp)
    end
    return reg
end

function apply!(reg::ArrayReg{B, T}, m::Roller{N}) where {B, N, T}
    st = statevec(reg)
    temp = Matrix{T}(undef, 1 << (N - 1), B)
    for block in m.blocks
        K = nqubits(block)
        mul!(st, mat(block), st)
        rolldims!(Val(K), Val(N), Val(B), st, temp)
    end
    return reg
end


@inline function rolldims2!(st::AbstractVector, temp::AbstractVector, halfn)
    @inbounds for k in 1:halfn
        temp[k] = st[2k]
    end
    @inbounds for k in 1:halfn
        st[k] = st[2k-1]
    end
    @inbounds for k in 1:halfn
        st[k+halfn] = temp[k]
    end
    return st
end

@inline function rolldims2!(st::AbstractMatrix, temp::AbstractMatrix, halfn::Int, nbatch::Int)
    @inbounds for j in 1:nbatch, k in 1:halfn
        temp[k, j] = st[2k, j]
    end
    @inbounds for j in 1:nbatch, k in 1:halfn
        st[k, j] = st[2k-1, j]
    end
    @inbounds for j in 1:nbatch, k in 1:halfn
        st[k+halfn, j] = temp[k, j]
    end
    return st
end


@generated function rolldims!(::Val{K}, ::Val{N}, ::Val{1}, st::AbstractVector, temp::AbstractVector) where {K, N, B}
    n = 1 << N
    halfn = 1 << (N - 1)
    ex = Expr(:block)
    for k in 1:K
        push!(ex.args, :(rolldims2!(st, temp, $halfn)))
    end
    push!(ex.args, :(return st))
    return ex
end

@generated function rolldims!(::Val{K}, ::Val{N}, ::Val{B}, st::AbstractMatrix, temp::AbstractMatrix) where {K, N, B}
    n = 1 << N
    halfn = 1 << (N - 1)
    ex = Expr(:block)
    for k in 1:K
        push!(ex.args, :(rolldims2!(st, temp, $halfn, $B)))
    end
    push!(ex.args, :(return st))
    return ex
end


Base.copy(m::Roller) = Roller(m.blocks)
Base.adjoint(blk::Roller) = Roller(map(adjoint, blk.blocks))