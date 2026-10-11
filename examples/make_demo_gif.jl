# make_demo_gif.jl — animated demo of the SukukLab pricing engine.
#
# Generates docs/demo.gif with pure Julia (standard library only): a tiny
# software rasterizer draws each frame and a small GIF89a writer with LZW
# compression assembles the animation. No image packages needed.
#
# Run from the repo root:
#   ~/.juliaup/bin/julia --project=. examples/make_demo_gif.jl
#
# The animation sweeps the market yield from 2% to 9% and reprices the UAE
# retail T-Sukuk (5-year, 5.06% annual, semi-annual, real published terms),
# the same instrument the Pluto notebook prices in section 1.

using SukukLab
using Dates

# ---------------------------------------------------------------- LZW ------
# GIF-variant LZW compressor. `pixels` holds color indices < 2^min_code_size.

function lzw_compress(pixels::Vector{UInt8}, min_code_size::Int)
    clear = 1 << min_code_size
    eoi = clear + 1
    out = UInt8[]
    bits_buf = 0
    bits_n = 0
    code_size = min_code_size + 1
    next_code = eoi + 1
    dict = Dict{UInt32,Int}()

    emit(code, cs) = begin
        bits_buf |= code << bits_n
        bits_n += cs
        while bits_n >= 8
            push!(out, bits_buf & 0xff)
            bits_buf >>= 8
            bits_n -= 8
        end
    end

    emit(clear, code_size)
    prefix = Int(pixels[1])
    for byte in pixels[2:end]
        key = UInt32((prefix << 8) | byte)
        hit = get(dict, key, -1)
        if hit != -1
            prefix = hit
        else
            emit(prefix, code_size)
            if next_code < 4096
                dict[key] = next_code
                next_code += 1
                next_code > (1 << code_size) &&
                    code_size < 12 && (code_size += 1)
            else
                emit(clear, code_size)
                empty!(dict)
                code_size = min_code_size + 1
                next_code = eoi + 1
            end
            prefix = Int(byte)
        end
    end
    emit(prefix, code_size)
    emit(eoi, code_size)
    bits_n > 0 && push!(out, bits_buf & 0xff)
    return out
end

# ---------------------------------------------------------------- GIF ------
# Minimal animated GIF89a writer: global color table, NETSCAPE loop,
# one graphic-control extension + image per frame.

struct GifCanvas
    w::Int
    h::Int
    palette::Vector{NTuple{3,UInt8}}
end

function gif_bytes(frames::Vector{Matrix{UInt8}}, canvas::GifCanvas,
                   delay_cs::Int)
    w, h = canvas.w, canvas.h
    ncolors = length(canvas.palette)
    @assert ncolors <= 256 && all(all(<(256), f) for f in frames)
    min_code = max(1, ceil(Int, log2(ncolors)))
    gct_size = 1 << min_code

    b = UInt8[]
    append!(b, codeunits("GIF89a"))
    append!(b, [w & 0xff, (w >> 8) & 0xff, h & 0xff, (h >> 8) & 0xff])
    # global color table flag, color resolution 111, size field
    push!(b, 0xf0 | (trailing_zeros(gct_size) - 1))
    push!(b, 0x00, 0x00)  # background index, aspect ratio
    for i in 1:gct_size
        c = i <= ncolors ? canvas.palette[i] : (0x00, 0x00, 0x00)
        append!(b, [c[1], c[2], c[3]])
    end
    # NETSCAPE2.0: loop forever
    append!(b, [0x21, 0xff, 0x0b])
    append!(b, codeunits("NETSCAPE2.0"))
    append!(b, [0x03, 0x01, 0x00, 0x00, 0x00])

    for f in frames
        # graphic control extension
        append!(b, [0x21, 0xf9, 0x04, 0x04,
                    delay_cs & 0xff, (delay_cs >> 8) & 0xff, 0x00, 0x00])
        # image descriptor
        append!(b, [0x2c, 0x00, 0x00, 0x00, 0x00,
                    w & 0xff, (w >> 8) & 0xff,
                    h & 0xff, (h >> 8) & 0xff, 0x00])
        push!(b, min_code)
        data = lzw_compress(vec(permutedims(f)), min_code)
        i = 1
        while i <= length(data)
            n = min(255, length(data) - i + 1)
            push!(b, n)
            append!(b, data[i:i+n-1])
            i += n
        end
        push!(b, 0x00)
    end
    push!(b, 0x3b)
    return b
end

# ---------------------------------------------------------- rasterizer -----
# Indexed-color canvas. 0 = white, 1 = black, 2 = blue, 3 = red.

function new_frame(w, h)
    return zeros(UInt8, h, w)
end

function blit!(f, x, y, color)
    1 <= x <= size(f, 2) && 1 <= y <= size(f, 1) && (f[y, x] = color)
end

function hline!(f, x1, x2, y, color)
    x1, x2 = minmax(x1, x2)
    for x in max(1, x1):min(size(f, 2), x2)
        f[y, x] = color
    end
end

function vline!(f, x, y1, y2, color)
    y1, y2 = minmax(y1, y2)
    for y in max(1, y1):min(size(f, 1), y2)
        f[y, x] = color
    end
end

function line!(f, x1, y1, x2, y2, color)
    # Bresenham
    dx, dy = abs(x2 - x1), -abs(y2 - y1)
    sx, sy = sign(x2 - x1), sign(y2 - y1)
    err = dx + dy
    x, y = x1, y1
    while true
        blit!(f, x, y, color)
        x == x2 && y == y2 && break
        e2 = 2 * err
        e2 >= dy && (err += dy; x += sx)
        e2 <= dx && (err += dx; y += sy)
    end
end

function disc!(f, cx, cy, r, color)
    for y in cy-r:cy+r, x in cx-r:cx+r
        (x - cx)^2 + (y - cy)^2 <= r^2 && blit!(f, x, y, color)
    end
end

# 3x5 bitmap font
const GLYPHS = Dict{Char,Vector{String}}(
    'A' => [".#.","#.#","###","#.#","#.#"],
    'B' => ["##.","#.#","##.","#.#","##."],
    'C' => [".##","#..","#..","#..",".##"],
    'D' => ["##.","#.#","#.#","#.#","##."],
    'E' => ["###","#..","##.","#..","###"],
    'F' => ["###","#..","##.","#..","#.."],
    'G' => [".##","#..","#.#","#.#",".##"],
    'H' => ["#.#","#.#","###","#.#","#.#"],
    'I' => ["###",".#.",".#.",".#.","###"],
    'J' => ["..#","..#","..#","#.#",".#."],
    'K' => ["#.#","#.#","##.","#.#","#.#"],
    'L' => ["#..","#..","#..","#..","###"],
    'M' => ["#.#","###","###","#.#","#.#"],
    'N' => ["#.#","###","###","###","#.#"],
    'O' => [".#.","#.#","#.#","#.#",".#."],
    'P' => ["##.","#.#","##.","#..","#.."],
    'Q' => [".#.","#.#","#.#","##.",".##"],
    'R' => ["##.","#.#","##.","#.#","#.#"],
    'S' => [".##","#..",".#.","..#","##."],
    'T' => ["###",".#.",".#.",".#.",".#."],
    'U' => ["#.#","#.#","#.#","#.#",".#."],
    'V' => ["#.#","#.#","#.#","#.#",".#."],
    'W' => ["#.#","#.#","###","###","#.#"],
    'X' => ["#.#","#.#",".#.","#.#","#.#"],
    'Y' => ["#.#","#.#",".#.",".#.",".#."],
    'Z' => ["###","..#",".#.","#..","###"],
    '0' => ["###","#.#","#.#","#.#","###"],
    '1' => [".#.","##.",".#.",".#.","###"],
    '2' => ["##.","..#",".#.","#..","###"],
    '3' => ["##.","..#",".#.","..#","##."],
    '4' => ["#.#","#.#","###","..#","..#"],
    '5' => ["###","#..","##.","..#","##."],
    '6' => [".#.","#..","##.","#.#",".#."],
    '7' => ["###","..#",".#.",".#.",".#."],
    '8' => [".#.","#.#",".#.","#.#",".#."],
    '9' => [".#.","#.#",".##","..#",".#."],
    '.' => ["...","...","...","...",".#."],
    '%' => ["#.#","..#",".#.","#..","#.#"],
    '-' => ["...","...","###","...","..."],
    '/' => ["..#","..#",".#.","#..","#.."],
    ' ' => ["...","...","...","...","..."],
)

function text!(f, x, y, s::AbstractString, color; scale=2)
    cx = x
    for ch in uppercase(s)
        g = get(GLYPHS, ch, GLYPHS[' '])
        for (r, row) in enumerate(g), (c, px) in enumerate(row)
            px == '#' || continue
            for dy in 1:scale, dx in 1:scale
                blit!(f, cx + (c - 1) * scale + dx - 1,
                      y + (r - 1) * scale + dy - 1, color)
            end
        end
        cx += 4 * scale
    end
end

# ---------------------------------------------------------------- demo -----
function main()
    # Real published terms: UAE sovereign retail T-Sukuk, second tranche.
    terms = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                       Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
    cfs = payment_schedule(terms)
    anchor = Date(2026, 10, 10)
    price(y) = price_from_cashflows(cfs, y, anchor; m=2)

    W, H = 480, 320
    px1, px2, py1, py2 = 64, 464, 36, 272   # plot area
    ylo, yhi = 0.02, 0.09                    # market yield sweep
    ys = collect(range(ylo, yhi; length=72))
    ps = [price(y) for y in ys]
    plo, phi = minimum(ps), maximum(ps)
    pad = 0.12 * (phi - plo)
    plo -= pad
    phi += pad
    X(y) = round(Int, px1 + (y - ylo) / (yhi - ylo) * (px2 - px1))
    Y(p) = round(Int, py2 - (p - plo) / (phi - plo) * (py2 - py1))

    canvas = GifCanvas(W, H, [(0xff, 0xff, 0xff), (0x1a, 0x1a, 0x1a),
                              (0x1f, 0x6f, 0xeb), (0xd6, 0x27, 0x28)])
    frames = Matrix{UInt8}[]
    nframes = 40
    for i in 1:nframes
        yc = ylo + (yhi - ylo) * (i - 1) / (nframes - 1)
        pc = price(yc)
        f = new_frame(W, H)
        # axes
        hline!(f, px1, px2, py2, 0x01); vline!(f, px1, py1, py2, 0x01)
        # gridlines + tick labels
        for gy in 0.02:0.01:0.09
            x = X(gy)
            vline!(f, x, py1, py2, 0x01)  # light touch: reuse black, 1px
            text!(f, x - 14, py2 + 8, "$(round(Int, 100gy))%", 0x01)
        end
        for gp in range(round(plo / 10) * 10, round(phi / 10) * 10; step=20)
            plo <= gp <= phi || continue
            y = Y(gp)
            hline!(f, px1, px2, y, 0x01)
            text!(f, 6, y - 5, "$(round(Int, gp))", 0x01)
        end
        # static price curve
        for j in 1:length(ys)-1
            line!(f, X(ys[j]), Y(ps[j]), X(ys[j+1]), Y(ps[j+1]), 0x02)
            line!(f, X(ys[j]), Y(ps[j]) + 1, X(ys[j+1]), Y(ps[j+1]) + 1, 0x02)
        end
        # moving dot
        disc!(f, X(yc), Y(pc), 6, 0x03)
        disc!(f, X(yc), Y(pc), 3, 0x00)
        # readout
        text!(f, px1, 8, "YIELD $(round(100yc; digits=2))%  PRICE $(round(pc; digits=2))", 0x01)
        text!(f, px1, py2 + 30, "UAE T-SUKUK 5Y 5.06 PCT - MARKET YIELD SWEEP", 0x01)
        push!(frames, f)
    end

    mkpath("docs")
    bytes = gif_bytes(frames, canvas, 12)  # 0.12 s per frame
    write("docs/demo.gif", bytes)
    println("wrote docs/demo.gif: $(length(bytes)) bytes, $(length(frames)) frames")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
