package agent_product

import agent_host_runtime.*
import agent_domain.*
import agent_store.*
import model_provider_runtime.*
import yjson.*
import yjson_support.*

// These names identify the shared owner's exact objects, never another root,
// mutex, database, file handle, or retained-resource registry.
public type ProductArtifact = HostArtifact
public type ProductArtifactRead = HostArtifactRead
public type ProductArtifactCapture = HostArtifactCapture
public type ProductArtifactStore = HostArtifactStore
type ProductProcessArtifactCapture = HostProcessArtifactCapture
let PRODUCT_ARTIFACT_PREVIEW_BYTES: Int64 = HOST_ARTIFACT_PREVIEW_BYTES
let PRODUCT_ARTIFACT_CONTENT_TYPE = HOST_ARTIFACT_CONTENT_TYPE
let PRODUCT_ARTIFACT_PREFIX = HOST_ARTIFACT_PREFIX

public func isProductArtifactReference(value: String): Bool { isHostArtifactReference(value) }
func artifactHash(reference: String): Result<String> { hostArtifactHash(reference) }
func artifactSha256(bytes: Array<Byte>): String { hostArtifactSha256(bytes) }
func artifactPreview(bytes: Array<Byte>, limit: Int64): String { hostArtifactPreview(bytes, limit) }
func artifactChmod(path: String, mode: String): Result<Unit> { hostArtifactChmod(path, mode) }
func captureProductProcessArtifacts(store: ?ProductArtifactStore, stdout: String,
    stderr: String): ProductProcessArtifactCapture { captureHostProcessArtifacts(store, stdout, stderr) }

// Compatibility delegates to the same Host pin/gate/store owner.
func stageProductModelPayload(artifacts: ProductArtifactStore, dispatch: ModelProviderDispatch,
    gate: ProductModelProviderDispatchGate, hexadecimal: String, maximum: Int64): Result<AgentValue> {
    stageHostModelPayload(artifacts, dispatch, gate, hexadecimal, maximum)
}
func readProductModelPayload(artifacts: ProductArtifactStore, dispatch: ModelProviderDispatch,
    gate: ProductModelProviderDispatchGate, payload: AgentValue, maximum: Int64): Result<Array<Byte>> {
    readHostModelPayload(artifacts, dispatch, gate, payload, maximum)
}

public func exportProductArtifact(
    store: ProductArtifactStore,
    reference: String,
    workspace: LocalWorkspace,
    destination: String
): Result<AgentValue> {
    let target = match (workspace.inspectWriteTarget(destination)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (target.permissionClass != "workspace.write") {
        return hostArtifactError<AgentValue>(
            AgentErrorKind.PermissionDenied,
            "artifact.export_outside_workspace",
            "artifact export destination must resolve inside the workspace",
            reference
        )
    }
    let content = store.readCompleteText(reference)
    let source = match (content) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (workspace.writeFile(destination, source)) {
        case Result.Ok(_) => Result.Ok(
            objectValue(
                [
                    ValueField("artifact_ref", textValue(reference)),
                    ValueField("path", textValue(target.normalizedPath)),
                    ValueField("bytes", integerValue(source.toArray().size)),
                    ValueField("content_type", textValue(PRODUCT_ARTIFACT_CONTENT_TYPE))
                ]
            )
        )
        case Result.Err(error) => Result.Err(error)
    }
}


