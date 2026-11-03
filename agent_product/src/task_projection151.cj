package agent_product

import agent_domain.*
import agent_host_runtime.*
import agent_extension_runtime.reserveNativeControlMetadata
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

class ProductTaskProjectionDecision151 {
    let kind: String
    let reference: Int64
    let failed: Bool
    init(kind: String, reference: Int64, failed: Bool) {
        this.kind = kind; this.reference = reference; this.failed = failed
    }
}



// Pay the old output wrapper and encoded JSON String before any construction.
// The original formatter body itself remains exact for compatibility.
