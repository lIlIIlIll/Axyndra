package yjson_support

import std.collection.*
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

public interface UnifiedJsonAccess {
    prop unifiedKind: UnifiedJsonKind
    prop text: String
    prop boolean: Bool
    prop number: String
    prop items: Array<JsonNode>
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
                case JsonKind.JsNull => UnifiedJsonKind.Null
                case JsonKind.JsBool => UnifiedJsonKind.Boolean
                case JsonKind.JsInt | JsonKind.JsFloat | JsonKind.JsNumberLiteral => UnifiedJsonKind.Number
                case JsonKind.JsString => UnifiedJsonKind.Text
                case JsonKind.JsArray => UnifiedJsonKind.List
                case JsonKind.JsObject => UnifiedJsonKind.Object
            }
        }
    }

    public prop text: String {
        get() {
            match (kind()) {
                case JsonKind.JsString => string
                case _ => YJson.stringify(this)
            }
        }
    }
    public prop boolean: Bool { get() { bool } }
    public prop number: String { get() { numberText } }
    public prop items: Array<JsonNode> {
        get() {
            match (kind()) {
                case JsonKind.JsArray => asArray().values().toArray()
                case _ => []
            }
        }
    }

    public prop fields: Array<JsonObjectEntry> {
        get() {
            if (kind() != JsonKind.JsObject) { return [] }
            let result = ArrayList<JsonObjectEntry>()
            for ((name, value) in asObject().entries()) {
                result.add(JsonObjectEntry(name, value))
            }
            let entries = result.toArray()
            var index = 0
            while (index < entries.size) {
                var smallest = index
                var candidate = index + 1
                while (candidate < entries.size) {
                    if (entries[candidate].name < entries[smallest].name) {
                        smallest = candidate
                    }
                    candidate++
                }
                if (smallest != index) {
                    let current = entries[index]
                    entries[index] = entries[smallest]
                    entries[smallest] = current
                }
                index++
            }
            entries
        }
    }

    public func field(name: String): ?JsonNode {
        match (kind()) {
            case JsonKind.JsObject => asObject().get(name)
            case _ => None
        }
    }

    public func put(name: String, value: JsonNode): Unit {
        this[name] = value
    }

    public func add(value: JsonNode): JsonNode {
        asArray().values().add(value)
        this
    }

    public func stringify(): String { YJson.stringify(this) }
}

public func parseUnifiedJson(
    source: String,
    maxBytes!: Int64 = 1048576,
    maxDepth!: Int64 = 64
): JsonNode {
    YJson.parse(
        source,
        config: JsonReadConfig(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            numberPolicy: JsonNumberPolicy.PreserveLiteral,
            maxDepth: maxDepth,
            maxStringBytes: maxBytes,
            maxBytes: maxBytes
        )
    )
}

public func stringifyUnifiedJson(value: JsonNode): String { YJson.stringify(value) }
public func quoteUnifiedJson(value: String): String { YJson.stringify(YJson.value(value)) }
public func jsonNull(): JsonNode { YJson.nullValue() }
public func jsonBool(value: Bool): JsonNode { YJson.value(value) }
public func jsonNumber(value: String): JsonNode { JsonNumberLiteralValue(value) }
public func jsonString(value: String): JsonNode { YJson.value(value) }
public func jsonArray(values: Array<JsonNode>): JsonNode { JsonArrayValue(values) }

public func jsonObject(fields: Array<JsonObjectEntry>): JsonNode {
    let value = JsonObjectValue()
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
    let errors = JsonSchema.fromValue(schema).validate(value)
    if (errors.isEmpty()) {
        None
    } else {
        let error = errors[0]
        Some(UnifiedJsonSchemaViolation(
            error.jsonPath,
            if (error.code == "schema_validation") {
                unifiedJsonSchemaKeyword(error.schemaPath)
            } else {
                error.code
            },
            error.message
        ))
    }
}

func unifiedJsonSchemaKeyword(schemaPath: String): String {
    let parts = schemaPath.split("/")
    if (parts.size == 0) { return "schema" }
    let last = parts.size - 1
    if (last > 0 && parts[last - 1] == "required") { return "required" }
    parts[last].replace("~1", "/").replace("~0", "~")
}
