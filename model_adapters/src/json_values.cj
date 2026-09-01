package model_adapters

import yjson.*
import yjson_support.*
import std.collection.*

// Runtime conversions used by the JSON literal macro. Keeping these conversions
// in the runtime package means the macro only rewrites syntax; escaping, number
// validation, and serialization still have one implementation.

public func toJsonNode(value: JsonNode): JsonNode {
    value
}

public func toJsonNode(value: String): JsonNode {
    jsonString(value)
}

public func toJsonNode(value: Bool): JsonNode {
    jsonBool(value)
}

public func toJsonNode(value: Int64): JsonNode {
    jsonNumber(value.toString())
}

public func toJsonNode(value: Float64): JsonNode {
    // Reuse the parser to reject NaN and infinities, which JSON cannot encode.
    parseUnifiedJson(value.toString())
}

public func rawJson(source: String): JsonNode {
    parseUnifiedJson(source)
}

public func rawJsonArray(items: Array<String>): JsonNode {
    let values = ArrayList<JsonNode>()
    for (item in items) {
        values.add(parseUnifiedJson(item))
    }
    jsonArray(values.toArray())
}
