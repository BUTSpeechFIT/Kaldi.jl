## io.jl input/output functions for Kaldi

## inspired by Kaldi source
uint16tofloat(x::UInt16, minvalue, range) = minvalue + range * x / typemax(UInt16)
function uint8tofloat(x::UInt8, quantiles)
    p0, p25, p75, p100 = quantiles
    if x ≤ 0x40
        return p0 + (p25 - p0) * x / 0x40
    elseif x ≤ 0xc0
        return p25 + (p75 - p25) * (x - 0x40) / 0x80
    else
        return p75 + (p100 - p75) * (x - 0xc0) / 0x3f
    end
end

readtoken(io::IO) = ascii(readuntil(io, ' '))
expecttoken(io::IO, token) = (t = readtoken(io)) == token || error("Expected ", token, ", saw ", t)

#function expectoneortwotokens(io::IO, token1, token2)
#    token = readtoken(io)
#    if token == token1
#        return expecttoken(io, token2)
#    else
#        return token == token2 || error("Expected ", token1, " or ", token2, ", saw ", token)
#    end
#end

## This loads a line of an scp, and returns a tuple (id, reader(fd) where id is the id of the record, and fd an open file stread where the data can
## be read from using `reader`.  We can't deliver a fd.  Well, we can if we read, and then wrap in a IOBuffer... Argh.
load_scp_record(io::IO) = Channel() do c
    while !eof(io)
        line = readline(io)
        words = split(line, ' ', limit=2)
        length(words) == 2 || continue
        id, value = strip.(words)
        length(value) > 0 || continue
        offset = 0
        if endswith(value, '|')
            cmd = split(value[1:end-1]) ## separate the command from the args for julia
            process = open(`$cmd`, "r")
            fd = IOBuffer(read(process.out))
        else
            m = match(r"^(.*):(\d+)$", value)
            if m != nothing
                value = m.captures[1]
                offset = parse(Int, m.captures[2])
            end
            fd = open(value, "r")
            offset > 0 && seek(fd, offset)
        end
        push!(c, (id, fd))
        close(fd)
    end
end

"""Reads a single binary matrix at the current position of io"""
function load_single_ark_matrix(io::IO)
    is_binary(io) || error("Only binary format is supported yet")
    token = readtoken(io)
    if token == "CM" ## compressed matrix
        minvalue, range = read(io, Float32, 2)
        nrow, ncol = read(io, Int32, 2)
        ret = Array{Float32}(nrow, ncol)
        quantiles = reshape([uint16tofloat(x, minvalue, range) for x in read(io, UInt16, 4*ncol)], (4, Int64(ncol)))
        for j in 1:ncol
            bytes = read(io, UInt8, nrow)
            for i in 1:nrow
                ret[i, j] = uint8tofloat(bytes[i], view(quantiles, :, j))
            end
        end
        return ret
    else
        if token == "FM"
            datatype = Float32
        elseif token == "DM"
            datatype = Float64
        else
            error("Unknown token ", token)
        end
        nrow = Int64(readint(io))
        ncol = Int64(readint(io))
        M = Matrix{datatype}(undef, nrow, ncol)
        return read!(io, M) 
    end
end


"""Reads a single binary vector at the current position of io"""
function load_single_ark_vector(io::IO)
    is_binary(io) || error("Only binary format is supported yet")
    len = readint(io)
    v = Vector{Int}()
    for i in 1:len
        v[i] = readint(io)
    end
    return v
end

## reads two bytes from io and checks that these are "\0B"
is_binary(io::IO) = read(io, UInt8) == 0 && read(io, Char) == 'B'

## This loads Kaldi matrices from an ark stream, one at the time
## we could probably also use code below
load_ark_matrix(io::IO) = Channel() do c
    while !eof(io)
        ## parse the index
        id = readtoken(io)
        push!(c, (id, load_single_ark_matrix(io)))
    end
end

function load_ark_matrices(fd::IO)
    data = OrderedDict{String, Matrix}()
    for (id, matrix) in load_ark_matrix(fd)
        data[id] = matrix
    end
    return data
end

load_ark_matrices(s::String) = open(s) do fd
    load_ark_matrices(fd)
end

load_ark_vector(io::IO) = Channel() do c
    while !eof(io)
        id = readtoken(io)
        push!(c, (id, load_single_ark_vector(io)))
    end
end

function load_ark_vectors(io::IO)
    data = OrderedDict{String, Vector}()
    for (id, vector) in load_ark_vector(io)
        data[id] = vector
    end
    return data
end

## save a single matrix with a key
function save_ark_matrix(fd::IO, key::String, value::Matrix{T}) where T<:AbstractFloat
    write(fd, key * " \0B")
    nrow, ncol = size(value)
    if T == Float32
        write(fd, "FM ")
    elseif T == Float64
        write(fd, "DM ")
    else
        error("Unknown floating point type ", T)
    end
    write(fd, UInt8(4), Int32(nrow), UInt8(4), Int32(ncol))
    write(fd, value')
end

## save multiple matrices as dict
save_ark_matrix(fd::IO, dict::AbstractDict{K,V}) where K<:AbstractString where V = for (k,v) in dict
    save_ark_matrix(fd, k, v)
end

function save_ark_matrix(fd::IO, keys::Vector{K}, values::Vector{Matrix{T}}) where K<:AbstractString where T<:AbstractFloat
    length(keys) == length(values) || error("Vector length mismatch")
    for (k,v) in zip(keys, values)
        save_ark_matrix(fd, k, v)
    end
end

save_ark_matrix(s::AbstractString, args...) = open(s, "w") do fd
    save_ark_matrix(fd, args...)
end

## nnet2 reading, we might want to rewrite some of the above code using routine below...

function load_nnet_am(io::IO)
    is_binary(io) || error("Expected binary header, sorry")
    tm = load_transition_model(io)
    nnet = load_nnet(io)
    NnetAM(tm, nnet)
end

function load_transition_model(io::IO)
    expecttoken(io, "<TransitionModel>")
    topo = load_hmm_topology(io)
    token = readtoken(io)
    if token == "<Triples>"
        tuples = [Tuple4(readint(io), readint(io), readint(io)) for i in 1:readint(io)]
        expecttoken(io, "</Triples>")
    elseif token == "<Tuples>"
        n = readint(io)
        tuples = [Tuple4(readint(io), readint(io), readint(io), readint(io)) for i in 1:n]
        expecttoken(io, "</Tuples>")
    end
    expecttoken(io, "<LogProbs>")
    log_probs = read_kaldi_array(io)
    expecttoken(io, "</LogProbs>")
    expecttoken(io, "</TransitionModel>")
    return TransitionModel(topo, tuples, log_probs)
end

function load_hmm_topology(io::IO)
    expecttoken(io, "<Topology>")
    phones = readvector(io, Int32)
    phone2idx = readvector(io, Int32)
    len = readint(io)
    hmm = true
    if len == -1
        hmm = false
        len = readint(io)
    end
    topo = Vector{TopologyEntry}(undef, len)
    for i in 1:len
        n = readint(io)
        e = Vector{HmmState}(undef, n)
        T = Any
        for j in 1:n
            pdf_class = readint(io)
            if !hmm
                self_pdf_class = readint(io)
            end
            t = [Transition(readint(io), readfloat(io)) for k in 1:readint(io)]
            ## we have to be carefull about the type, not sure if this is in any
            if j == 1
                T = eltype(t[1])
            end
            e[j] = HmmState(pdf_class, Transition{T}[x for x in t])
        end
        topo[i] = TopologyEntry(e)
    end
    expecttoken(io, "</Topology>")
    return topo
end

## recursive list of subtypes, I may be doing this not so efficiently
function recursivesubtypes(t)
    res = []
    s = subtypes(t)
    for tt in s
        if length(subtypes(tt)) == 0
            push!(res, tt)
        else
            for ttt in recursivesubtypes(tt)
                push!(res, ttt)
            end
        end
    end
    return res
end

function load_nnet(io::IO, T=Float32)
    ## nnet
    token = readtoken(io)
    if token == "<Nnet>"
        expecttoken(io, "<NumComponents>")
        n = readint(io)
        components = NnetComponent[]
        expecttoken(io, "<Components>")
        ## take care of type names, strip off "Kalid." prefix and type parameters
        componentdict = Dict(replace(split(string(t),".")[end], r"{\w+}", "")  => t for t in recursivesubtypes(NnetComponent))
        for i in 1:n
            kind = readtoken(io)[2:end-1] ## remove < >
            kind ∈ keys(componentdict) || error("Unknown Nnet component ", kind)
            push!(components, load_nnet_component(io, componentdict[kind], T))
            expecttoken(io, "</$kind>")
        end
        expecttoken(io, "</Components>")
        expecttoken(io, "</Nnet>")
        ## priors
        priors = read_kaldi_array(io)
        return Nnet(components, priors)
    elseif token == "<Nnet3>"
        return nothing
    end
end

function load_nnet_component(io::IO, ::Type{SpliceComponent}, T::Type)
    input_dim = readint(io, "<InputDim>")
    token = readtoken(io)
    if token == "<LeftContext>"
        leftcontext = readint(io)
        rightcontext = readint(io, "<RightContext>")
        context = collect(-leftcontext:rightcontext)
    elseif token == "<Context>"
        context = readvector(io, Int32)
    else
        error("Unexpected token ", token)
    end
    const_component_dim = readint(io, "<ConstComponentDim>")
    return SpliceComponent{T}(input_dim, const_component_dim, context)
end

function load_nnet_component(io::IO, ::Type{FixedAffineComponent}, T::Type)
    linear_params = read_kaldi_array(io, "<LinearParams>")
    bias_params = read_kaldi_array(io, "<BiasParams>")
    # t = promote_type(eltype(linear_params), eltype(bias_params))
    return FixedAffineComponent{T}(linear_params, bias_params)
end

function load_nnet_component(io::IO, ::Type{AffineComponentPreconditionedOnline}, T::Type)
    learning_rate = readfloat(io, "<LearningRate>")
    linear_params = read_kaldi_array(io, "<LinearParams>")
    bias_params = read_kaldi_array(io, "<BiasParams>")
    token = readtoken(io)
    if token == "<Rank>"
        rank_out = rank_in = readint(io)
    elseif token == "<RankIn>"
        rank_in = readint(io)
        rank_out = readint(io, "<RankOut>")
    else
        error("Unexpected token ", token)
    end
    token = readtoken(io)
    if token == "<UpdatePeriod>"
        update_period = readint(io)
        expecttoken(io, "<NumSamplesHistory>")
    elseif token == "<NumSamplesHistory>"
        update_period = 1
    else
        error("Unexpected token ", token)
    end
    num_samples_history = readfloat(io)
    alpha = readfloat(io, "<Alpha>")
    max_change_per_sample = readfloat(io, "<MaxChangePerSample>")
    return AffineComponentPreconditionedOnline{T}(learning_rate, linear_params, bias_params, rank_in, rank_out, update_period, num_samples_history, alpha, max_change_per_sample)
end

function load_nnet_component(io::IO, ::Type{PnormComponent}, T::Type)
    input_dim = readint(io, "<InputDim>")
    output_dim = readint(io, "<OutputDim>")
    p = readfloat(io, "<P>")
    return PnormComponent{T}(input_dim, output_dim, p)
end

function load_nnet_component(io::IO, ::Type{NormalizeComponent}, T::Type)
    dim = readint(io, "<Dim>")
    value_sum = read_kaldi_array(io, "<ValueSum>")
    deriv_sum = read_kaldi_array(io, "<DerivSum>")
    count = readint(io, "<Count>")
    return NormalizeComponent{T}(dim, value_sum, deriv_sum, count)
end

function load_nnet_component(io::IO, ::Type{FixedScaleComponent}, T::Type)
    scales = read_kaldi_array(io, "<Scales>")
    return FixedScaleComponent{T}(scales)
end

function load_nnet_component(io::IO, ::Type{SoftmaxComponent}, T::Type)
    dim = readint(io, "<Dim>")
    value_sum = read_kaldi_array(io, "<ValueSum>")
    deriv_sum = read_kaldi_array(io, "<DerivSum>")
    count = readint(io, "<Count>")
    return SoftmaxComponent{T}(dim, value_sum, deriv_sum, count)
end

function load_nnet_component(io::IO, ::Type{C}, T::Type) where C<:NnetComponent
    println(readtoken(io))
end


function readint(io, token="")
    if token != ""
        expecttoken(io, token)
    end
    s = read(io, UInt8)
    if s == 4
        return read(io, Int32)
    elseif s == 8
        return read(io, Int64)
    else
        error("Unknown int size ", s)
    end
end

function readfloat(io, token="")
    if token != ""
        expecttoken(io, token)
    end
    s = read(io, UInt8)
    if s == 4
        return read(io, Float32)
    elseif s == 8
        return read(io, Float64)
    else
        error("Unknown float size ", s)
    end
end

## only used for Int32?
function readvector(io::IO, t::Type)
    s = read(io, UInt8)
    len = read(io, Int32)
    s == sizeof(t) || error("Type size check failed: ", s, " ", sizeof(t))
    v = Vector{t}(undef, len)
    return read!(io, v)
end

## This reads a Kaldi-encoded vector or matrix
function read_kaldi_array(io::IO, token="")
    if token != ""
        expecttoken(io, token)
    end
    token = readtoken(io)
    length(token) == 2 || error("Unexpected token length ", length(token))
    if token[1] == 'F'
        datatype = Float32
    elseif token[1] == 'D'
        datatype = Float64
    else
        error("Unknown element type ", token[1])
    end
    if token[2] == 'V'
        len = readint(io)
        v = Vector{datatype}(undef, len)
        return read!(io, v)
    elseif token[2] == 'M'
        nrow = Int(readint(io))
        ncol = Int(readint(io))
        M = Matrix{datatype}(undef, nrow*ncol)
        return read!(io, M)
    else
        error("Unknown array type")
    end
end
