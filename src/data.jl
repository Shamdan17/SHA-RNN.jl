using Base.Iterators, IterTools

struct Vocab
    v2i::Dict{String,Int16}
    i2v::Vector{String}
    unk::Int16
    eos::Int16
    tokenizer
end

function Vocab(file::String; tokenizer=split, vocabsize=Inf, mincount=1, unk="<unk>", eos="<s>")
    # set unk and eos tokens frequency to inf because
    # we don't want them to be removed from the vocab set
    cdict = Dict(eos => Inf, unk=>Inf) 
    
    # create vocab set and count occurrences
    for l in eachline(file)
        tokens = tokenizer(l)
        map(v -> cdict[v] = get!(cdict, v, 0) + 1, tokens)
    end
    
    # select vocabs with frequency higher than mincount
    # sort by frequency and delete if vocabsize is determined
    fsorted = sort([ (v, c) for (v, c) in cdict if c >= mincount ], by = x -> x[2], rev = true)
    
    vocabsize == Inf || length(fsorted) < vocabsize || (fsorted = fsorted[1:vocabsize])

    i2v = [ eos; unk; [ x[1] for x in fsorted[3:end] ] ]
    v2i = Dict( v => i for (i, v) in enumerate(i2v))                
    
    return Vocab(v2i, i2v, v2i[unk], v2i[eos], tokenizer)
end
                
struct TextReader
    file::String
    vocab::Vocab
end
                
function Base.iterate(r::TextReader, s=nothing)
    s === nothing && (s = open(r.file))
    eof(s) && return close(s)
    return [[ get(r.vocab.v2i, v, r.vocab.unk) for v in r.vocab.tokenizer(readline(s))] ; [ r.vocab.eos, ] ] , s
end
                
Base.IteratorSize(::Type{TextReader}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{TextReader}) = Base.HasEltype()
Base.eltype(::Type{TextReader}) = Vector{Int16}

mutable struct TextData
    src::TextReader             # reader for text data
    batchsize::Int              # desired batch size
    batchmajor::Bool            # batch dims (B,T) if batchmajor=false (default) or (T,B) if true.
    dataarray::Array{Int16, 2} # batchified data array for language modeling tasks
    maxsize::Int                # max length of text to read
    bptt::Int                   # how many steps to back propagate through time
    randomize::Bool             # randomize BPTT
end

function TextData(src::TextReader; batchsize = 128, maxlength = typemax(Int),
                batchmajor = false, maxsize = typemax(Int), bptt = 1024, randomize = true)
    datavector = Vector{Int16}()
    nr = lb = length(datavector)

    for l in src
        for i in l
            nr += 1
            if nr > lb
                lb = nr * 2
                resize!(datavector, lb)
            end

            datavector[nr] = i
            if nr > maxsize
                datavector = resize!(datavector, maxsize)
                @goto escape_label
            end
        end
    end
    @label escape_label
    datavector = resize!(datavector, nr)
    N = length(datavector) ÷ batchsize
    batchified_dataarray = reshape(datavector[1:N * batchsize], N, batchsize)'
    TextData(src, batchsize, batchmajor, batchified_dataarray, maxsize, bptt, randomize)
end

function changebatchsize!(d::TextData, newbatchsize::Int)
    (B, N) = size(d.dataarray)
    datavector = reshape(d.dataarray', N * B)
    N = length(datavector) ÷ newbatchsize
    d.dataarray = reshape(datavector[1:N * newbatchsize], N, newbatchsize)'
    d.batchsize = newbatchsize
    return newbatchsize
end

Base.IteratorSize(::Type{TextData}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{TextData}) = Base.HasEltype()
Base.eltype(::Type{TextData}) = Tuple{Array{Int16,2},Array{Int16,2}}

function Base.iterate(d::TextData, state=nothing)
    if state === nothing
        state = (1, d.bptt + 1) 
    elseif state == 0
        return nothing
    end

    while true
        x = d.dataarray[:, state[1]:state[2]]        
        (d.batchmajor) && (x = x')
        batch = (x[:, 1:end-1], x[:, 2:end])

        if state[2] >= size(d.dataarray, 2)
            return batch, 0
        elseif d.randomize
            seq_len = (rand([1,1,1,1,1,1,1,1,1,0]) == 1) ? d.bptt : (d.bptt ÷ 2) # get half of bptt 10% of the time.
            next_bptt = Int(gaussian(1; mean=seq_len, std=5)[1] ÷ 1)
            starting_idx = state[2]
            ending_idx = state[2] + next_bptt
            state = (starting_idx, ending_idx)
        else
            state = state .+ d.bptt
        end
        
        if state[2] >= size(d.dataarray, 2)
            state = (state[1], size(d.dataarray, 2))
        end
        
        return batch, state
    end
end

nothing