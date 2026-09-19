package yjson_support

import std.collection.*
import std.convert.*
import yjson.*


public enum UnifiedJsonKind <: Equatable<UnifiedJsonKind> {
    Null | Boolean | Number | Text | List | Object

    public operator func ==(other: UnifiedJsonKind): Bool {
        match ((this, other)) {
            case (Null, Null) | (Boolean, Boolean) | (Number, Number) |
                 (Text, Text) | (List, List) | (Object, Object) => true
            case _ => false
        }
    }
}

public class JsonObjectEntry {
    public let name: String
    public let value: JsonNode

    public init(name: String, value: JsonNode) {
        this.name = name
        this.value = value
    }
}

public class UnifiedJsonSchemaViolation {
    public let path: String
    public let keyword: String
    public let message: String

    public init(path: String, keyword: String, message: String) {
        this.path = path
        this.keyword = keyword
        this.message = message
    }
}

public class UnifiedJsonItems <: Iterable<JsonNode> {
    private let array: Option<JsonArray>
    private let fallback: ArrayList<JsonNode>

    public init(array: Option<JsonArray>) {
        this.array = array
        this.fallback = ArrayList<JsonNode>()
    }

    public prop size: Int64 {
        get() {
            match (array) {
                case Some(value) => value.size()
                case None => fallback.size
            }
        }
    }

    public func isEmpty(): Bool { size == 0 }

    public func get(index: Int64): ?JsonNode {
        match (array) {
            case Some(value) => value.get(index)
            case None => fallback.get(index)
        }
    }

    public operator func [](index: Int64): JsonNode {
        get(index).getOrThrow()
    }

    public operator func [](index: Int64, value!: JsonNode): Unit {
        match (array) {
            case Some(target) => target.set(index, value)
            case None => fallback[index] = value
        }
    }

    public func add(value: JsonNode): Unit {
        match (array) {
            case Some(target) => target.insert(target.size(), value)
            case None => fallback.add(value)
        }
    }

    public func remove(at!: Int64): JsonNode {
        match (array) {
            case Some(target) => target.removeAt(at)
            case None => fallback.remove(at: at)
        }
    }

    public func clear(): Unit {
        while (size > 0) { remove(at: size - 1) }
    }

    public func toArray(): Array<JsonNode> {
        let result = ArrayList<JsonNode>()
        for (index in 0..size) { result.add(get(index).getOrThrow()) }
        result.toArray()
    }

    public func iterator(): Iterator<JsonNode> {
        let snapshot = ArrayList<JsonNode>()
        for (index in 0..size) { snapshot.add(get(index).getOrThrow()) }
        snapshot.iterator()
    }
}

public interface UnifiedJsonAccess {
    prop unifiedKind: UnifiedJsonKind
    prop text: String
    prop boolValue: Bool
    prop numberText: String
    prop items: UnifiedJsonItems
    prop fields: Array<JsonObjectEntry>
    func field(name: String): ?JsonNode
    func put(name: String, value: JsonNode): Unit
    func add(value: JsonNode): JsonNode
    func stringify(): String
}

extend JsonNode <: UnifiedJsonAccess {
    public prop unifiedKind: UnifiedJsonKind {
        get() {
            match (kind()) {
                case JsonKind.Null => UnifiedJsonKind.Null
                case JsonKind.Boolean => UnifiedJsonKind.Boolean
                case JsonKind.Number => UnifiedJsonKind.Number
                case JsonKind.String => UnifiedJsonKind.Text
                case JsonKind.Array => UnifiedJsonKind.List
                case JsonKind.Object => UnifiedJsonKind.Object
            }
        }
    }

    public prop text: String {
        get() {
            match (kind()) {
                case JsonKind.String => asString()
                case _ => toJson()
            }
        }
    }
    public prop boolValue: Bool { get() { asBool() } }
    public prop numberText: String { get() { asNumberText() } }
    public prop items: UnifiedJsonItems {
        get() {
            match (kind()) {
                case JsonKind.Array => UnifiedJsonItems(Some<JsonArray>(asArray()))
                case _ => UnifiedJsonItems(None<JsonArray>)
            }
        }
    }

    public prop fields: Array<JsonObjectEntry> {
        get() {
            if (kind() != JsonKind.Object) { return [] }
            let object = asObject()
            let result = ArrayList<JsonObjectEntry>()
            for (index in 0..object.size()) {
                result.add(JsonObjectEntry(object.nameAt(index), object.valueAt(index)))
            }
            result.toArray()
        }
    }

    public func field(name: String): ?JsonNode {
        match (kind()) {
            case JsonKind.Object => asObject().get(name)
            case _ => None
        }
    }

    public func put(name: String, value: JsonNode): Unit {
        this[name] = value
    }

    public func add(value: JsonNode): JsonNode {
        let array = asArray()
        array.insert(array.size(), value)
        this
    }

    public func stringify(): String { toJson() }
}

public func parseUnifiedJson(
    source: String,
    maxBytes!: Int64 = 1048576,
    maxDepth!: Int64 = 64
): JsonNode {
    JsonNode.parse(
        source,
        config: JsonReadOptions(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            maxDepth: maxDepth,
            maxStringBytes: maxBytes,
            maxInputBytes: maxBytes,
            maxBufferedValueBytes: maxBytes
        )
    )
}

public func stringifyUnifiedJson(value: JsonNode): String { value.toJson() }
public func quoteUnifiedJson(value: String): String { JsonNode.string(value).toJson() }
public func jsonNull(): JsonNode { JsonNode.nullValue }
public func jsonBool(value: Bool): JsonNode { JsonNode.boolean(value) }
public func jsonNumber(value: String): JsonNode { JsonNode.number(value) }
public func jsonString(value: String): JsonNode { JsonNode.string(value) }
public func jsonArray(values: Array<JsonNode>): JsonNode { JsonNode.array(values) }

public func jsonObject(fields: Array<JsonObjectEntry>): JsonNode {
    let value = JsonObject()
    for (field in fields) {
        if (value.contains(field.name)) {
            throw JsonException(
                "duplicate JSON object key: " + field.name,
                code: "duplicate_key"
            )
        }
        value[field.name] = field.value
    }
    value
}

public func validateUnifiedJsonSchema(
    schema: JsonNode,
    value: JsonNode
): ?UnifiedJsonSchemaViolation {
    try {
        let errors = JsonSchema.fromValue(schema).validate(value)
        if (errors.isEmpty()) {
            None
        } else {
            let error = errors[0]
            Some(UnifiedJsonSchemaViolation(
                unifiedJsonInstancePath(error.instancePath),
                if (error.code == "schema_validation") {
                    unifiedJsonSchemaKeyword(error.schemaPath)
                } else {
                    error.code
                },
                error.message
            ))
        }
    } catch (error: Exception) {
        Some(UnifiedJsonSchemaViolation("", "schema", error.message))
    }
}

func unifiedJsonInstancePath(instancePath: String): String {
    if (instancePath.isEmpty()) { return "$" }
    let segments = instancePath.split("/")
    var result = "$"
    for (segment in segments) {
        if (segment.isEmpty()) { continue }
        let decoded = segment.replace("~1", "/").replace("~0", "~")
        try {
            let index = Int64.parse(decoded)
            if (index.toString() == decoded) {
                result = result + "[" + decoded + "]"
            } else {
                result = result + "[" + quoteUnifiedJson(decoded) + "]"
            }
        } catch (_: Exception) {
            result = result + "[" + quoteUnifiedJson(decoded) + "]"
        }
    }
    result
}

func unifiedJsonSchemaKeyword(schemaPath: String): String {
    let parts = schemaPath.split("/")
    if (parts.size == 0) { return "schema" }
    let last = parts.size - 1
    if (last > 0 && parts[last - 1] == "required") { return "required" }
    parts[last].replace("~1", "/").replace("~0", "~")
}
