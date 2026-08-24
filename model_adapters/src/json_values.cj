package model_adapters

import json4cj.*
import std.collection.*

// Runtime conversions used by the JSON literal macro. Keeping these conversions
// in the runtime package means the macro only rewrites syntax; escaping, number
// validation, and serialization still have one implementation.

public func toJsonValue(value: JsonValue): JsonValue {
    value
}

public func toJsonValue(value: String): JsonValue {
    JsonValue.stringValue(value)
}

public func toJsonValue(value: Bool): JsonValue {
    JsonValue.boolValue(value)
}

public func toJsonValue(value: Int64): JsonValue {
    JsonValue.numberValue(value.toString())
}

public func toJsonValue(value: Float64): JsonValue {
    // Reuse the parser to reject NaN and infinities, which JSON cannot encode.
    parseJson(value.toString())
}

public func rawJson(source: String): JsonValue {
    parseJson(source)
}

public func rawJsonArray(items: Array<String>): JsonValue {
    let values = ArrayList<JsonValue>()
    for (item in items) {
        values.add(parseJson(item))
    }
    JsonValue.arrayValue(values.toArray())
}
