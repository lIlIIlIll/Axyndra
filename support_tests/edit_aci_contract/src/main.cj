package edit_aci_contract

import agent_domain.*
import agent_product.*
import std.env.*

main(): Int64 {
    let root = requiredEnvironment("EDIT_ACI_WORKSPACE")
    let path = requiredEnvironment("EDIT_ACI_PATH")
    let range = requiredEnvironment("EDIT_ACI_RANGE")
    let replacement = requiredEnvironment("EDIT_ACI_REPLACEMENT")
    let workspace = LocalWorkspace(root)
    let current = workspace.read(WorkspaceReadRequest(path)).value().getOrThrow().content
    let rows = replacement.split("\n")
    var patch = "[" + path + "#" + hashlineTag(current) + "]\nSWAP " + range + ":"
    for (row in rows) { patch += "\n+" + row }
    let mutation = applyHashlineEdit(patch, {candidate =>
        match (workspace.read(WorkspaceReadRequest(candidate))) {
            case Result.Ok(value) => Result.Ok(value.content)
            case Result.Err(error) => Result.Err(error)
        }
    }).value().getOrThrow()
    let _ = workspace.commit(mutation).value().getOrThrow()
    println("edit ACI contract applied path=" + path + " range=" + range)
    0
}

func requiredEnvironment(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing environment: " + name)
    }
}
