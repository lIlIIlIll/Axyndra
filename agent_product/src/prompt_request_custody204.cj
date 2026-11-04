package agent_product

import agent_core.*
import agent_domain.*
import yjson_support.*

// The caller reserves this on its existing Catalog bank before project
// discovery, instruction reads, rendering, or prompt hashing. Content is added
// by the bounded reader using each actual file witness, rather than reserving
// hypothetical instruction files for every ancestor.
func productUnscopedPromptInvoice204(workspaceRoot: String, guide: String,
    modeSystem: String, requestText: String): Int64 {
    let inputs = workspaceRoot.size + guide.size + modeSystem.size + requestText.size
    let limit: Int64 = 1073741824
    if (workspaceRoot.size > (limit - 65536) / 2048 || inputs > limit / 256) {
        throw LogicalJsonPayloadError("request prompt metadata exceeds its DATA envelope")
    }
    let paths = (workspaceRoot.size * 32 + 1024) * 64
    let invoice = 262144 + paths + inputs * 256
    if (invoice > limit) {
        throw LogicalJsonPayloadError("request prompt metadata exceeds its DATA envelope")
    }
    invoice
}

func buildProductUnscopedPromptPaid204(workspaceRoot: String, guide: String,
    modeSystem: String, payment: LogicalJsonOwnerReservation,
    initialInvoice: Int64): ProductScopedPrompt {
    let meter = TaskInstructionDataMeter204(payment, initialInvoice)
    let context = loadProductProjectContextFrame204(workspaceRoot, None<TaskContextScope>, Some(meter))
    let prompt = buildProductPromptFromContext(context, "", guide, modeSystem, "")
    ProductScopedPrompt(prompt, objectValue([]), retainedAllocation204: Some(payment))
}
