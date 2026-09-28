package plugin_performance_baseline

import agent_extension_runtime.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*

class RecordingLauncher <: JavaScriptHostProcessLauncher {
    var pid: Int64 = 0

    public func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess> {
        try {
            let process = startProcess(command)
            pid = process.pid
            JavaScriptHostResult.Ok(process)
        } catch (error: Exception) {
            JavaScriptHostResult.Err(JavaScriptHostError("extension.process_spawn_failed", error.message))
        }
    }
}

func identity(suffix: String): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(
        threadId: "thread-bench",
        runId: "run-bench",
        epoch: 1,
        operationId: "operation-" + suffix,
        callId: "call-" + suffix
    )
}

func requiredEnvironment(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing environment variable: " + name)
    }
}

func elapsedMicros(started: MonoTime): Int64 {
    max((MonoTime.now() - started).toMicroseconds(), 0)
}

func rssBytes(pid: Int64): Int64 {
    let status = String.fromUtf8(File.readFrom(Path("/proc/" + pid.toString() + "/status")))
    for (line in status.split("\n") where line.startsWith("VmRSS:")) {
        for (field in line.replace("VmRSS:", "").replace("kB", "").split(" ")) {
            let value = field.trimAscii()
            if (value != "") { return Int64.parse(value) * 1024 }
        }
    }
    throw IllegalStateException("VmRSS is unavailable for extension host")
}

func ordered(values: ArrayList<Int64>): Array<Int64> {
    let result = values.toArray()
    for (index in 1..result.size) {
        let current = result[index]
        var target = index
        while (target > 0 && result[target - 1] > current) {
            result[target] = result[target - 1]
            target -= 1
        }
        result[target] = current
    }
    result
}

func percentile(values: ArrayList<Int64>, percent: Int64): Int64 {
    let sorted = ordered(values)
    let rank = max(1, (percent * sorted.size + 99) / 100)
    sorted[min(sorted.size - 1, rank - 1)]
}

func metric(name: String, values: ArrayList<Int64>, unit: String): Unit {
    println("{\"metric\":\"" + name + "\",\"samples\":" + values.size.toString() +
        ",\"p50\":" + percentile(values, 50).toString() +
        ",\"p95\":" + percentile(values, 95).toString() +
        ",\"unit\":\"" + unit + "\"}")
}

main(): Int64 {
    let root = requiredEnvironment("AXYNDRA_FIXTURE_ROOT")
    let cold = ArrayList<Int64>()
    let first = ArrayList<Int64>()
    let steady = ArrayList<Int64>()
    let memory = ArrayList<Int64>()
    let cancellation = ArrayList<Int64>()

    for (sample in 0..12) {
        let launcher = RecordingLauncher()
        let coldStarted = MonoTime.now()
        let host = match (startJavaScriptExtensionHostWithLauncher(
            JavaScriptHostLaunchRequest(
                root,
                "pi_echo_v1.js",
                extensionId: "pi.performance",
                extensionVersion: "1.0.0",
                generation: UInt64(sample + 1)
            ),
            launcher
        )) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        cold.add(elapsedMicros(coldStarted))

        let firstStarted = MonoTime.now()
        match (host.invoke("echo", "{\"value\":\"first\"}", identity: identity("first-" + sample.toString()))) {
            case JavaScriptHostResult.Ok(_) => ()
            case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        first.add(elapsedMicros(firstStarted))

        for (call in 0..20) {
            let steadyStarted = MonoTime.now()
            match (host.invoke(
                "echo",
                "{\"value\":\"steady\"}",
                identity: identity("steady-" + sample.toString() + "-" + call.toString())
            )) {
                case JavaScriptHostResult.Ok(_) => ()
                case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            steady.add(elapsedMicros(steadyStarted))
        }
        memory.add(rssBytes(launcher.pid))
        host.close()
    }

    for (sample in 0..12) {
        let launcher = RecordingLauncher()
        let host = match (startJavaScriptExtensionHostWithLauncher(
            JavaScriptHostLaunchRequest(
                root,
                "pi_echo_v2.ts",
                extensionId: "pi.performance.cancel",
                extensionVersion: "1.0.0",
                generation: UInt64(sample + 101)
            ),
            launcher
        )) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        let source = CancellationSource()
        let trigger = spawn {
            sleep(Duration.millisecond * 100)
            source.cancel()
        }
        let started = MonoTime.now()
        let result = host.invoke(
            "delayed",
            "{}",
            identity: identity("cancel-" + sample.toString()),
            cancellation: source.token,
            timeoutMillis: 4000
        )
        cancellation.add(elapsedMicros(started))
        let _ = trigger.get()
        match (result) {
            case JavaScriptHostResult.Err(error) => if (error.code != "process.cancelled") {
                throw IllegalStateException(error.code + ": " + error.message)
            }
            case JavaScriptHostResult.Ok(_) => throw IllegalStateException("cancelled invocation completed")
        }
        source.close()
        host.close()
    }

    metric("extension_cold_start", cold, "us")
    metric("extension_first_call", first, "us")
    metric("extension_steady_ipc", steady, "us")
    metric("extension_host_rss", memory, "bytes")
    metric("extension_cancel_after_100ms_trigger", cancellation, "us")
    0
}
