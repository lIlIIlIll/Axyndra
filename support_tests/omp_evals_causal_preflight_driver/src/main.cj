package omp_evals_causal_preflight_driver

import agent_domain.*
import agent_product.*
import std.env.*
import std.fs.*

main(): Int64 {
    let root = requiredEnvironment("EDIT_REPLAY_WORKSPACE")
    let payloadPath = requiredEnvironment("EDIT_REPLAY_PAYLOAD_FILE")
    let payload = String.fromUtf8(File.readFrom(payloadPath))
    let workspace = LocalWorkspace(root)
    let parsed = applyHashlineEdit(payload, {candidate =>
        match (workspace.read(WorkspaceReadRequest(candidate))) {
            case Result.Ok(value) => Result.Ok(value.content)
            case Result.Err(error) => Result.Err(error)
        }
    })
    match (parsed) {
        case Result.Err(error) =>
            println("REJECT\t" + error.code + "\t" + error.message)
            return 2
        case Result.Ok(mutation) =>
            if (environment("EDIT_REPLAY_PARSE_ONLY") == "1") {
                println("ACCEPTED\t" + mutation.path)
                return 0
            } else {
                match (workspace.commit(mutation)) {
                    case Result.Err(error) =>
                        println("APPLICATION_ERROR\t" + error.code + "\t" + error.message)
                        return 3
                    case Result.Ok(_) =>
                        println("APPLIED\t" + mutation.path)
                        return 0
                }
            }
    }
}

func requiredEnvironment(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing environment: " + name)
    }
}

func environment(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => ""
    }
}
