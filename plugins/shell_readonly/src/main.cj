package shell_readonly_plugin

import agent_domain.*
import std.env.*
import yjson.*
import yjson_support.*

main(): Int64 {
    let arguments = getCommandLine()
    try {
        if (arguments.size == 3 && arguments[1] == "--view-worker-file" && srRelative(arguments[2])) {
            let charge=srPayloadProcess.acquire(2097152)
            try {
                // Prepay input/raw capture/pump copies/hash/base64/JSON before
                // reading the file or starting either original bounded pump.
                charge.ensureDecoded(4194304,8192)
                srEmit(srExecuteWorker(srReadWorkerInput(), defaultWorkingDirectory: arguments[2])); return 0
            } finally {charge.close()} }
        if (arguments.size != 1) { return 2 }
        srRunProtocol()
    } catch (error: ReadonlyShellFailure) {
        if (arguments.size == 3) { srEmit(jsonObject([JsonObjectEntry("error", jsonString(error.code))])) }
        3
    } catch (_: Exception) { 3 }
}
