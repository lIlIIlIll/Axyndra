package product_contract

import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.sync.*
import process4cj as process

// Original Native Registry aliases retain their paid high-water mark. Each
// scenario therefore runs a whole real process lifetime, without resetting
// its bank, changing its quota or substituting a cleanup acknowledgement.
func runPlanExecutionProductContracts(parent: String): Unit {
    for (mode in ["primary", "drain", "unknown", "revision", "process-scope", "native-shell-refusal", "request-custody"]) {
        planProductRunCaseProcess204(mode, parent)
    }
}

func planProductWorkerMode204(): ?String {
    match (getVariable("AXYNDRA_PLAN_PRODUCT_CASE204")) {
        case Some(value) =>
            if (!["primary", "drain", "unknown", "revision", "process-scope", "native-shell-refusal", "request-custody"].contains(value)) {
                throw IllegalArgumentException("unknown product plan contract case") }
            Some(value)
        case None => None<String>
    }
}

func planProductWorkerMain204(mode: String): Int64 {
    let parent = getVariable("AXYNDRA_PLAN_PRODUCT_ROOT204").getOrThrow()
    let root = Directory.createTemp(parent).toString()
    var complete = false
    try {
        match (mode) {
            case "primary" => runPlanExecutionPrimaryContract204(root)
            case "drain" => runPlanHardBudgetDrainContract(root)
            case "unknown" => runPlanUnknownMutationStopsContract(root)
            case "revision" => runPlanRevisionControlContract(root)
            case "process-scope" => runPlanProcessScopeContract(root)
            case "native-shell-refusal" => runPlanNativeShellRefusalContract(root)
            case "request-custody" => runPlanRequestCustodyProductContract204(root)
            case _ => throw IllegalArgumentException("unknown product plan contract case")
        }
        complete = true
    } finally { if (complete) { let _ = removeIfExists(root, recursive: true) } }
    println("product-plan-process case=" + mode + " completed=true")
    0
}

func planProductRunCaseProcess204(mode: String, parent: String): Unit {
    let environment = HashMap<String, String>()
    for ((name, value) in getVariables()) { environment[name] = value }
    environment["AXYNDRA_PLAN_PRODUCT_CASE204"] = mode
    environment["AXYNDRA_PLAN_PRODUCT_ROOT204"] = canonicalize(Path(parent)).toString()
    var output: ?Future<Array<Byte>> = None<Future<Array<Byte>>>
    var error: ?Future<Array<Byte>> = None<Future<Array<Byte>>>
    var code: Int64 = -1
    var stdout: Array<Byte> = []
    var stderr: Array<Byte> = []
    var waited = false
    let child = process.startProcess(process.ProcessCommand(canonicalize(Path("/proc/self/exe")).toString(),
        workingDirectory: canonicalize(Path(".")).toString(), environment: environment, maxOutputBytes: 16384))
    try {
        // Reader construction is inside the same physical child cleanup
        // frame. A second-spawn failure must join the first real reader too.
        output = Some(spawn { planProductDrainPipe204(child.stdout) })
        error = Some(spawn { planProductDrainPipe204(child.stderr) })
        code = child.wait().code
        waited = true
    } finally {
        try {
            if (!waited) {
                // This is the fixture's actual child process, not a business
                // operation or a synthetic completion acknowledgement.
                try { let _ = child.terminate(force: true) }
                finally { let _ = child.wait() }
            }
        } finally {
            try { match (output) { case Some(value) => stdout = value.get(); case None => () } }
            finally {
                try { match (error) { case Some(value) => stderr = value.get(); case None => () } }
                finally { child.close() }
            }
        }
    }
    if (code != 0) {
        println(String.fromUtf8(stdout).replace(parent, "<fixture>"))
        println(String.fromUtf8(stderr).replace(parent, "<fixture>"))
    }
    expect(code == 0, "independent real Product plan process " + mode + " completed with status " + code.toString())
    println("product-plan-process case=" + mode + " joined=true")
}

private func planProductDrainPipe204(stream: InputStream): Array<Byte> {
    let buffer = Array<Byte>(4096, repeat: 0)
    let output = ArrayList<Byte>()
    while (true) {
        let count = stream.read(buffer)
        if (count <= 0) { break }
        for (index in 0..count where output.size < 16384) { output.add(buffer[index]) }
    }
    output.toArray()
}
