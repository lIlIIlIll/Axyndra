println(stdout, "READY|jl|1"); flush(stdout)
state = Module(:OmpEval)
while !eof(stdin)
    line = readline(stdin)
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
            seekstart(out); seekstart(err)
            join(["OK", string(exit_code), timed_out ? "1" : "0", string(duration), bytes2hex(read(out)), bytes2hex(read(err))], '|')
        end
    end
    println(stdout, response)
    flush(stdout)
end
