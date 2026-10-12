package shell_readonly_plugin

import agent_domain.*
import process4cj.*
import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func srReadWorkerInput(): JsonNode {
    let input = File(Path(getWorkingDirectory().toString()).join(".axyndra-worker-input.json"), OpenMode.Read)
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
    try {
        while (true) {
            let count = input.read(buffer); if (count == 0) { break }
            srRequire(count > 0 && bytes.size + count <= SR_INPUT_BYTES, code: "shell_readonly.input_limit")
            for (index in 0..count) { bytes.add(buffer[index]) } }
        srValidate(parseUnifiedJson(String.fromUtf8(bytes.toArray()), maxBytes: SR_INPUT_BYTES, maxDepth: 32))
    } finally { input.close() }
}
func srReadOutput(stream: InputStream, budget: BoundedOutputBudget): Array<Byte> {
    let result = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = stream.read(buffer); if (count == 0) { break }
        srRequire(count > 0, code: "shell_readonly.output_failed")
        let keep = budget.claim(count)
        for (index in 0..keep) { result.add(buffer[index]) } }
    result.toArray()
}
func srExecuteWorker(input: JsonNode, defaultWorkingDirectory!: String = "."): JsonNode {
    // Only this --view-worker-file branch performs effects, after the Host has
    // admitted its real Derived read-view child and installed isolated RO/Denied.
    let checked = srValidate(input)
    let view = getWorkingDirectory().toString()
    srRequire(srRelative(defaultWorkingDirectory), code: "shell_readonly.cwd_invalid")
    let cwd = Path(view).join(if (srText(checked, "cwd") == "") { defaultWorkingDirectory } else { srText(checked, "cwd") }).normalize()
    srRequire(cwd.toString() == view || cwd.toString().startsWith(view + "/"), code: "shell_readonly.cwd_invalid")
    var command = ""
    if (checked.field("env").isSome()) {
        for (entry in srField(checked, "env").fields) { command += "export " + entry.name + "=" + srQuote(entry.value.text) + "; " } }
    command += srText(checked, "command")
    let process = startProcess(ProcessCommand("/bin/bash", arguments: ["--noprofile", "--norc", "-lc", command],
        workingDirectory: cwd.toString(), maxOutputBytes: SR_CAPTURE_BYTES, terminateProcessTree: true))
    let budget = BoundedOutputBudget(SR_CAPTURE_BYTES)
    let out = spawn { srReadOutput(process.stdout, budget) }
    let err = spawn { srReadOutput(process.stderr, budget) }
    let deadline = MonoTime.now() + Duration.millisecond * srTimeout(checked)
    var timedOut = false
    try {
        let _ = process.closeInput()
        while (process.tryExit().isNone() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (process.tryExit().isNone()) { timedOut = true; let _ = process.terminate(force: true) }
        let status = process.wait().code
        // Exit never substitutes for ownership cleanup. Kill retained descendants,
        // close actual pipes and join both bounded pumps before reporting output.
        let _ = process.terminate(force: true)
        let stdout = out.get(); let stderr = err.get()
        let _ = process.close()
        jsonObject([JsonObjectEntry("exit_code", jsonNumber(if (timedOut) { "124" } else { status.toString() })),
            JsonObjectEntry("stdout", srEncodeCaptured(stdout)), JsonObjectEntry("stderr", srEncodeCaptured(stderr)),
            JsonObjectEntry("timed_out", jsonBool(timedOut)), JsonObjectEntry("truncated", jsonBool(budget.wasTruncated()))])
    } finally {
        let _ = process.close()
        let _ = out.get(); let _ = err.get()
    }
}
