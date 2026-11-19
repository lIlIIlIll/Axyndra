println(stdout, "READY|jl|1"); flush(stdout)
using SHA
state = Module(:OmpEval)
while !eof(stdin)
    line = readline(stdin)
    artifacts = startswith(line, "A|")
    binding_id = ""
    if artifacts
        _, binding_id, line = split(line, '|'; limit=3)
    end
    started = time_ns()
    response = mktemp() do _, out
        mktemp() do _, err
            exit_code = 0
            timed_out = false
            try
                parts = split(line, '|'; limit=3)
                reset_text = parts[2]
                global state = reset_text == "1" ? Module(gensym(:OmpEval)) : state
                code = String(hex2bytes(parts[3]))
                value = redirect_stdout(out) do
                    redirect_stderr(err) do
                        Base.include_string(state, code, "<eval>")
                    end
                end
                value === nothing || println(out, repr(value))
            catch error
                exit_code = 1
                showerror(err, error, catch_backtrace())
            end
            duration = Int((time_ns() - started) ÷ 1_000_000)
            flush(out); flush(err)
            sizes = (position(out), position(err))
            seekstart(out); seekstart(err)
            if artifacts && sum(sizes) > 4096
                sum(sizes) <= 16777216 || error("cell output exceeds artifact bound")
                println(stdout, join(["OUT", binding_id, exit_code, timed_out ? 1 : 0, duration, sizes[1],
                    bytes2hex(sha256(out)), sizes[2], bytes2hex(sha256(err))], '|'))
                for stream in (out, err)
                    seekstart(stream)
                    while !eof(stream)
                        chunk = read(stream, 16384)
                        if !eof(stream)
                            while (peek(stream, UInt8) & 0xc0) == 0x80
                                isempty(chunk) && error("invalid output encoding")
                                seek(stream, position(stream) - 1); pop!(chunk)
                            end
                        end
                        println(stdout, bytes2hex(chunk))
                    end
                end
                "END|" * binding_id
            else
                join([artifacts ? "INLINE|" * binding_id : "OK", string(exit_code), timed_out ? "1" : "0", string(duration), bytes2hex(read(out)), bytes2hex(read(err))], '|')
            end
        end
    end
    println(stdout, response)
    flush(stdout)
end
