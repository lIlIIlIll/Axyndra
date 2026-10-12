package program_plugin

import agent_domain.*
import yjson.*
import yjson_support.*

// Business mapping only. The descriptor describes bytes retained by the Host;
// it neither grants this process a Store/FS port nor changes a Tool Source.
func programInputAttachment(invocation: JsonNode, code: String): ?JsonNode {
    let value = match (invocation.field("input_attachment")) { case Some(found) => found; case None => return None }
    require(toolInputAttachmentEvidenceValid(value))
    let profile = value.field("profile").getOrThrow()
    let artifact = value.field("artifact").getOrThrow()
    require(httpIntentText(profile, "field") == "code" && readonlyDelegationInteger(profile, "max_bytes") == 262144 &&
        httpIntentText(value, "namespace") == "axyndra:" + stringField(invocation, "extension_id") &&
        httpIntentText(value, "generation") == invocation.field("generation").getOrThrow().asNumberText() &&
        httpIntentText(value, "thread_id") == stringField(invocation, "thread_id") &&
        httpIntentText(value, "run_id") == stringField(invocation, "run_id") &&
        canonicalAgentValue(value.field("epoch").getOrThrow()) == canonicalAgentValue(invocation.field("epoch").getOrThrow()) &&
        httpIntentText(value, "operation_id") == stringField(invocation, "operation_id") &&
        httpIntentText(value, "call_id") == stringField(invocation, "call_id") &&
        readonlyDelegationInteger(artifact, "bytes") == code.size &&
        httpIntentText(artifact, "sha256") == modelPolicySha256Text(code) &&
        httpIntentText(artifact, "ref") == "blob:sha256:" + modelPolicySha256Text(code))
    Some(artifact)
}

func programWithInputAttachment(output: JsonNode, attachment: ?JsonNode): JsonNode {
    match (attachment) {
        case None => output
        case Some(value) =>
            output.put("program_artifact", value.field("ref").getOrThrow())
            output.put("program_sha256", value.field("sha256").getOrThrow())
            output.put("program_sdk", jsonString("program-language-v1/native-readonly-v1"))
            output.put("output_truncated", jsonBool(false))
            output
    }
}
