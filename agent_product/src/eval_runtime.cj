package agent_product

import agent_domain.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.io.*
import std.process.*
import std.sync.*

public class EvalExecutionResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let durationMillis: Int64
    public let transportClosed: Bool

    public init(
        exitCode: Int64,
        stdout!: String = "",
        stderr!: String = "",
        timedOut!: Bool = false,
        durationMillis!: Int64 = 0,
        transportClosed!: Bool = false
    ) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
        this.durationMillis = durationMillis
        this.transportClosed = transportClosed
    }
}

class PersistentEvalKernel {
    let sessionId: SessionId
    let language: String
    let sandboxProfile: String
    let process: SubProcess
    private let executeLock = Mutex()
    private var closed: Bool = false

    init(
        sessionId: SessionId,
        language: String,
        sandboxProfile: String,
        process: SubProcess
    ) {
        this.sessionId = sessionId
        this.language = language
        this.sandboxProfile = sandboxProfile
        this.process = process
    }

    func isAlive(): Bool {
        !closed
    }

    func close(): Unit {
        closed = true
        try {
            process.terminate(force: true)
        } catch (_: Exception) {}
    }

    func execute(
        code: String,
        reset: Bool,
        timeoutMillis: Int64
    ): Result<EvalExecutionResult> {
        executeLock.lock()
        try {
            if (!isAlive()) {
                return Result.Ok(EvalExecutionResult(
                    -1,
                    stderr: "eval runtime exited before the cell started",
                    transportClosed: true
                ))
            }
            let request = timeoutMillis.toString() + "|" +
                (if (reset) { "1" } else { "0" }) + "|" +
                evalHexEncode(code) + "\n"
            let responseFuture = spawn {
                readEvalProtocolLine(process.stdOutPipe)
            }
            try {
                process.stdInPipe.write(request.toArray())
                process.stdInPipe.flush()
            } catch (error: Exception) {
                return Result.Err(evalRuntimeError(
                    "eval.runtime_write_failed",
                    error.message
                ))
            }
            var waited: Int64 = 0
            let hostLimit = timeoutMillis + 1000
            while (responseFuture.tryGet().isNone() &&
                   waited < hostLimit) {
                sleep(Duration.millisecond * 10)
                waited += 10
            }
            if (responseFuture.tryGet().isNone()) {
                close()
                return Result.Ok(EvalExecutionResult(
                    124,
                    stderr: "eval cell timed out after " +
                        evalTimeoutSeconds(timeoutMillis) + "s",
                    timedOut: true,
                    durationMillis: timeoutMillis,
                    transportClosed: true
                ))
            }
            parseEvalResponse(responseFuture.get())
        } finally {
            executeLock.unlock()
        }
    }
}

class EvalRuntimeCommand {
    let executable: String
    let arguments: Array<String>

    init(executable: String, arguments: Array<String>) {
        this.executable = executable
        this.arguments = arguments
    }
}

func evalRuntimeCommand(language: String): Result<EvalRuntimeCommand> {
    let executable: String
    let arguments: Array<String>
    match (language) {
        case "py" =>
            executable = "/usr/bin/python3"
            arguments = ["-u", "-c", pythonEvalRunner()]
        case "js" =>
            executable = "/usr/bin/bun"
            arguments = ["--eval", javascriptEvalRunner()]
        case "rb" =>
            executable = "/usr/bin/ruby"
            arguments = ["-e", rubyEvalRunner()]
        case "jl" =>
            executable = "/usr/bin/julia"
            arguments = [
                "--startup-file=no",
                "--history-file=no",
                "-e",
                juliaEvalRunner()
            ]
        case _ =>
            return Result.Err(evalRuntimeError(
                "eval.language_unsupported",
                "unsupported eval language: " + language
            ))
    }
    Result.Ok(EvalRuntimeCommand(executable, arguments))
}

// Persistent eval must be launched with the raw bwrap argv produced by
// WorkspaceSandbox.plan. The timeout wrapper is intentionally not used here:
// cell deadlines are enforced by the protocol while the isolated kernel stays
// alive for later cells.
func startEvalKernel(
    sessionId: SessionId,
    language: String,
    sandboxProfile: String,
    sandboxExecutable: String,
    sandboxArguments: Array<String>
): Result<PersistentEvalKernel> {
    try {
        let process = launch(
            sandboxExecutable,
            sandboxArguments,
            environment: HashMap<String, String>(),
            stdIn: ProcessRedirect.Pipe,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe
        )
        Result.Ok(PersistentEvalKernel(
            sessionId,
            language,
            sandboxProfile,
            process
        ))
    } catch (error: Exception) {
        Result.Err(evalRuntimeError(
            "eval.runtime_start_failed",
            error.message
        ))
    }
}

func parseEvalResponse(line: String): Result<EvalExecutionResult> {
    if (line == "") {
        return Result.Ok(EvalExecutionResult(
            -1,
            stderr: "eval runtime closed without a response",
            transportClosed: true
        ))
    }
    let fields = line.trimAscii().split("|")
    if (fields.size == 2 && fields[0] == "ERR") {
        return Result.Err(evalRuntimeError(
            "eval.runtime_protocol",
            evalHexDecode(fields[1])
        ))
    }
    if (fields.size != 6 || fields[0] != "OK") {
        return Result.Err(evalRuntimeError(
            "eval.runtime_protocol",
            "invalid eval runtime response"
        ))
    }
    let exitCode = parseEvalInteger(fields[1], -1)
    let timedOut = fields[2] == "1"
    let duration = parseEvalInteger(fields[3], 0)
    Result.Ok(EvalExecutionResult(
        exitCode,
        stdout: evalHexDecode(fields[4]),
        stderr: evalHexDecode(fields[5]),
        timedOut: timedOut,
        durationMillis: duration
    ))
}

func readEvalProtocolLine(stream: InputStream): String {
    match (readLineBounded(stream, 33554432, allowPartialAtEof: true)) {
        case Some(value) => value
        case None => ""
    }
}

func evalHexEncode(source: String): String {
    let alphabet = "0123456789abcdef"
    let alphabetBytes = unsafe { alphabet.rawData() }
    let output = ArrayList<Byte>()
    for (byte in unsafe { source.rawData() }) {
        let value = UInt32(byte)
        output.add(alphabetBytes[Int64((value >> 4) & 15)])
        output.add(alphabetBytes[Int64(value & 15)])
    }
    String.fromUtf8(output.toArray())
}

func evalHexDecode(source: String): String {
    let bytes = unsafe { source.rawData() }
    if (bytes.size % 2 != 0) { return "invalid hex payload" }
    let output = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < bytes.size) {
        let high = evalHexNibble(bytes[index])
        let low = evalHexNibble(bytes[index + 1])
        if (high < 0 || low < 0) { return "invalid hex payload" }
        output.add(UInt8(high * 16 + low))
        index += 2
    }
    try {
        String.fromUtf8(output.toArray())
    } catch (_: Exception) {
        "invalid UTF-8 eval payload"
    }
}

func evalHexNibble(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') {
        return Int64(value - b'0')
    }
    if (value >= b'a' && value <= b'f') {
        return Int64(value - b'a') + 10
    }
    if (value >= b'A' && value <= b'F') {
        return Int64(value - b'A') + 10
    }
    -1
}

func parseEvalInteger(value: String, fallback: Int64): Int64 {
    try { Int64.parse(value) } catch (_: Exception) { fallback }
}

func evalTimeoutSeconds(timeoutMillis: Int64): String {
    if (timeoutMillis % 1000 == 0) {
        (timeoutMillis / 1000).toString()
    } else {
        (Float64(timeoutMillis) / 1000.0).toString()
    }
}

func evalRuntimeError(code: String, message: String): AgentError {
    AgentError(
        AgentErrorKind.Transport,
        code,
        message
    )
}

func pythonEvalRunner(): String {
    "import ast, asyncio, contextlib, inspect, io, json, signal, sys, time, traceback\n" +
    "state = {}\n" +
    "def install():\n" +
    "    def display(value):\n" +
    "        try:\n" +
    "            if isinstance(value, (dict, list, tuple, bool, int, float)) or value is None:\n" +
    "                print(json.dumps(value, ensure_ascii=False, default=str))\n" +
    "            else:\n" +
    "                print(value)\n" +
    "        except Exception:\n" +
    "            print(repr(value))\n" +
    "    state.update({'__name__': '__main__', 'display': display})\n" +
    "install()\n" +
    "class CellTimeout(Exception): pass\n" +
    "def alarm_handler(signum, frame): raise CellTimeout()\n" +
    "signal.signal(signal.SIGALRM, alarm_handler)\n" +
    "def run_awaitable(value):\n" +
    "    if inspect.isawaitable(value): return asyncio.run(value)\n" +
    "    return value\n" +
    "while True:\n" +
    "    line = sys.stdin.buffer.readline()\n" +
    "    if not line: break\n" +
    "    started = time.monotonic()\n" +
    "    out, err, exit_code, timed_out = io.StringIO(), io.StringIO(), 0, False\n" +
    "    try:\n" +
    "        timeout_text, reset_text, payload = line.decode().rstrip('\\n').split('|', 2)\n" +
    "        timeout_ms = int(timeout_text)\n" +
    "        if reset_text == '1':\n" +
    "            state = {}\n" +
    "            install()\n" +
    "        code = bytes.fromhex(payload).decode('utf-8')\n" +
    "        signal.setitimer(signal.ITIMER_REAL, timeout_ms / 1000.0)\n" +
    "        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):\n" +
    "            tree = ast.parse(code, mode='exec')\n" +
    "            if tree.body and isinstance(tree.body[-1], ast.Expr):\n" +
    "                prefix = ast.Module(body=tree.body[:-1], type_ignores=[])\n" +
    "                if prefix.body:\n" +
    "                    value = eval(compile(prefix, '<eval>', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), state)\n" +
    "                    run_awaitable(value)\n" +
    "                expression = ast.Expression(tree.body[-1].value)\n" +
    "                value = eval(compile(expression, '<eval>', 'eval', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), state)\n" +
    "                value = run_awaitable(value)\n" +
    "                if value is not None: state['display'](value)\n" +
    "            else:\n" +
    "                value = eval(compile(tree, '<eval>', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), state)\n" +
    "                run_awaitable(value)\n" +
    "    except CellTimeout:\n" +
    "        timed_out, exit_code = True, 124\n" +
    "        err.write('eval cell timed out after ' + str(timeout_ms / 1000).rstrip('0').rstrip('.') + 's')\n" +
    "    except BaseException:\n" +
    "        exit_code = 1\n" +
    "        traceback.print_exc(file=err)\n" +
    "    finally:\n" +
    "        signal.setitimer(signal.ITIMER_REAL, 0)\n" +
    "    duration = int((time.monotonic() - started) * 1000)\n" +
    "    response = 'OK|%d|%d|%d|%s|%s\\n' % (exit_code, int(timed_out), duration, out.getvalue().encode().hex(), err.getvalue().encode().hex())\n" +
    "    sys.stdout.write(response)\n" +
    "    sys.stdout.flush()\n"
}

func javascriptEvalRunner(): String {
    "import vm from 'node:vm';\n" +
    "import { createRequire } from 'node:module';\n" +
    "import readline from 'node:readline';\n" +
    "const require = createRequire(import.meta.url);\n" +
    "let context;\n" +
    "function fresh() {\n" +
    "  context = vm.createContext({ Buffer, fetch, process, require, setTimeout, clearTimeout, URL, TextEncoder, TextDecoder });\n" +
    "}\n" +
    "fresh();\n" +
    "const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });\n" +
    "for await (const line of rl) {\n" +
    "  const started = Date.now(); let out = []; let err = []; let exitCode = 0; let timedOut = false;\n" +
    "  try {\n" +
    "    const first = line.indexOf('|'), second = line.indexOf('|', first + 1);\n" +
    "    const timeoutMs = Number(line.slice(0, first));\n" +
    "    if (line.slice(first + 1, second) === '1') fresh();\n" +
    "    const code = Buffer.from(line.slice(second + 1), 'hex').toString('utf8');\n" +
    "    const format = value => typeof value === 'string' ? value : Bun.inspect(value);\n" +
    "    context.console = { log: (...v) => out.push(v.map(format).join(' ')), error: (...v) => err.push(v.map(format).join(' ')), warn: (...v) => err.push(v.map(format).join(' ')) };\n" +
    "    context.print = (...v) => out.push(v.map(format).join(' '));\n" +
    "    context.display = value => out.push(typeof value === 'string' ? value : JSON.stringify(value, null, 2));\n" +
    "    const asyncCell = /(^|[^A-Za-z0-9_$])await\\s|(^|\\n)\\s*return\\b/.test(code);\n" +
    "    const source = asyncCell ? '(async()=>{\\n' + code + '\\n})()' : code;\n" +
    "    let value = new vm.Script(source, { filename: '<eval>' }).runInContext(context, { timeout: timeoutMs });\n" +
    "    if (value && typeof value.then === 'function') {\n" +
    "      value = await Promise.race([value, new Promise((_, reject) => setTimeout(() => reject(new Error('__OMP_EVAL_TIMEOUT__')), timeoutMs))]);\n" +
    "    }\n" +
    "    if (value !== undefined) context.display(value);\n" +
    "  } catch (e) {\n" +
    "    const message = String(e && e.stack ? e.stack : e);\n" +
    "    timedOut = message.includes('__OMP_EVAL_TIMEOUT__') || message.includes('Script execution timed out');\n" +
    "    exitCode = timedOut ? 124 : 1;\n" +
    "    err.push(timedOut ? 'eval cell timed out' : message);\n" +
    "  }\n" +
    "  const encode = value => Buffer.from(value).toString('hex');\n" +
    "  process.stdout.write('OK|' + exitCode + '|' + (timedOut ? 1 : 0) + '|' + (Date.now() - started) + '|' + encode(out.join('\\n')) + '|' + encode(err.join('\\n')) + '\\n');\n" +
    "  if (timedOut) setImmediate(() => process.exit(0));\n" +
    "}\n"
}

func rubyEvalRunner(): String {
    "require 'stringio'\n" +
    "require 'timeout'\n" +
    "def fresh_binding\n" +
    "  Object.new.instance_eval { binding }\n" +
    "end\n" +
    "state = fresh_binding\n" +
    "STDIN.each_line do |line|\n" +
    "  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)\n" +
    "  out = StringIO.new\n" +
    "  err = StringIO.new\n" +
    "  exit_code = 0\n" +
    "  timed_out = false\n" +
    "  begin\n" +
    "    timeout_text, reset_text, payload = line.chomp.split('|', 3)\n" +
    "    timeout_ms = Integer(timeout_text)\n" +
    "    state = fresh_binding if reset_text == '1'\n" +
    "    code = [payload].pack('H*').force_encoding('UTF-8')\n" +
    "    previous_out, previous_err = $stdout, $stderr\n" +
    "    begin\n" +
    "      $stdout, $stderr = out, err\n" +
    "      value = Timeout.timeout(timeout_ms / 1000.0) { eval(code, state, '<eval>') }\n" +
    "      puts(value.inspect) unless value.nil?\n" +
    "    ensure\n" +
    "      $stdout, $stderr = previous_out, previous_err\n" +
    "    end\n" +
    "  rescue Timeout::Error\n" +
    "    timed_out = true\n" +
    "    exit_code = 124\n" +
    "    err.write('eval cell timed out')\n" +
    "  rescue Exception => error\n" +
    "    exit_code = 1\n" +
    "    err.write(([error.full_message].compact).join(\"\\n\"))\n" +
    "  end\n" +
    "  duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).to_i\n" +
    "  response = ['OK', exit_code, timed_out ? 1 : 0, duration, out.string.unpack1('H*'), err.string.unpack1('H*')].join('|')\n" +
    "  STDOUT.write(response + \"\\n\")\n" +
    "  STDOUT.flush\n" +
    "end\n"
}

func juliaEvalRunner(): String {
    "state = Module(:OmpEval)\n" +
    "while !eof(stdin)\n" +
    "    line = readline(stdin)\n" +
    "    started = time_ns()\n" +
    "    out = IOBuffer()\n" +
    "    err = IOBuffer()\n" +
    "    exit_code = 0\n" +
    "    timed_out = false\n" +
    "    try\n" +
    "        parts = split(line, '|'; limit=3)\n" +
    "        reset_text = parts[2]\n" +
    "        global state = reset_text == \"1\" ? Module(gensym(:OmpEval)) : state\n" +
    "        code = String(hex2bytes(parts[3]))\n" +
    "        value = redirect_stdout(out) do\n" +
    "            redirect_stderr(err) do\n" +
    "                Base.include_string(state, code, \"<eval>\")\n" +
    "            end\n" +
    "        end\n" +
    "        value === nothing || println(out, repr(value))\n" +
    "    catch error\n" +
    "        exit_code = 1\n" +
    "        showerror(err, error, catch_backtrace())\n" +
    "    end\n" +
    "    duration = Int((time_ns() - started) ÷ 1_000_000)\n" +
    "    println(stdout, join([\"OK\", string(exit_code), timed_out ? \"1\" : \"0\", string(duration), bytes2hex(take!(out)), bytes2hex(take!(err))], '|'))\n" +
    "    flush(stdout)\n" +
    "end\n"
}
