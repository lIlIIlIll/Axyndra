package json4cj

import std.convert.*

// Deterministic validation for the provider-portable JSON Schema subset used
// by protocol descriptors. Unknown keywords remain annotations.
public class JsonSchemaViolation {
    public let path: String
    public let keyword: String
    public let message: String
    public init(path: String, keyword: String, message: String) {
        this.path = path; this.keyword = keyword; this.message = message
    }
}

public func validateJsonSchema(schema: JsonValue, value: JsonValue): ?JsonSchemaViolation {
    validateJsonSchemaAt(schema, value, "$")
}

func validateJsonSchemaAt(schema: JsonValue, value: JsonValue, path: String): ?JsonSchemaViolation {
    if (schema.kind == JsonKind.Boolean) {
        if (schema.boolean) { return None }
        return Some(JsonSchemaViolation(path, "falseSchema", "value is rejected by the false schema"))
    }
    if (schema.kind != JsonKind.Object) { return invalidJsonSchema(path, "schema must be an object or boolean") }
    match (schema.field("anyOf")) {
        case Some(options) =>
            if (options.kind != JsonKind.List || options.items.isEmpty()) {
                return invalidJsonSchema(path, "anyOf must be a non-empty array of schemas")
            }
            var matched = false
            for (option in options.items) {
                if (validateJsonSchemaAt(option, value, path).isNone()) { matched = true; break }
            }
            if (!matched) { return Some(JsonSchemaViolation(path, "anyOf", "value does not match any allowed schema")) }
        case None => ()
    }
    match (schema.field("enum")) {
        case Some(allowed) =>
            if (allowed.kind != JsonKind.List) { return invalidJsonSchema(path, "enum must be an array") }
            var matched = false
            for (candidate in allowed.items) { if (jsonSchemaValuesEqual(candidate, value)) { matched = true; break } }
            if (!matched) { return Some(JsonSchemaViolation(path, "enum", "value is not one of the allowed values")) }
        case None => ()
    }
    match (schema.field("type")) {
        case Some(expected) =>
            let nullable = match (schema.field("nullable")) {
                case Some(candidate) => candidate.kind == JsonKind.Boolean && candidate.boolean
                case None => false
            }
            if (!(nullable && value.kind == JsonKind.Null) && !jsonSchemaTypeMatches(expected, value)) {
                return Some(JsonSchemaViolation(path, "type", "value does not match declared type"))
            }
        case None => ()
    }
    match (value.kind) {
        case JsonKind.Object => validateJsonObject(schema, value, path)
        case JsonKind.List => validateJsonArray(schema, value, path)
        case JsonKind.Text => validateJsonString(schema, value, path)
        case _ => None
    }
}

func validateJsonObject(schema: JsonValue, value: JsonValue, path: String): ?JsonSchemaViolation {
    match (schema.field("required")) {
        case Some(required) =>
            if (required.kind != JsonKind.List) { return invalidJsonSchema(path, "required must be an array") }
            for (entry in required.items) {
                if (entry.kind != JsonKind.Text) { return invalidJsonSchema(path, "required entries must be strings") }
                if (value.field(entry.text).isNone()) {
                    return Some(JsonSchemaViolation(jsonSchemaPath(path, entry.text), "required", "required property is missing"))
                }
            }
        case None => ()
    }
    let properties: ?JsonValue = match (schema.field("properties")) {
        case Some(candidate) =>
            if (candidate.kind != JsonKind.Object) { return invalidJsonSchema(path, "properties must be an object") }
            Some(candidate)
        case None => None
    }
    let additional = schema.field("additionalProperties")
    for (field in value.fields) {
        let fieldPath = jsonSchemaPath(path, field.name)
        let declared: ?JsonValue = match (properties) {
            case Some(candidate) => candidate.field(field.name)
            case None => None
        }
        match (declared) {
            case Some(candidate) => match (validateJsonSchemaAt(candidate, field.value, fieldPath)) {
                case Some(error) => return Some(error)
                case None => ()
            }
            case None => match (additional) {
                case Some(candidate) =>
                    if (candidate.kind == JsonKind.Boolean && !candidate.boolean) {
                        return Some(JsonSchemaViolation(fieldPath, "additionalProperties", "additional property is not allowed"))
                    }
                    if (candidate.kind != JsonKind.Boolean) {
                        match (validateJsonSchemaAt(candidate, field.value, fieldPath)) {
                            case Some(error) => return Some(error)
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
    }
    None
}

func validateJsonArray(schema: JsonValue, value: JsonValue, path: String): ?JsonSchemaViolation {
    match (jsonSchemaLimit(schema, "minItems", path)) {
        case Some((limit, error)) => match (error) {
            case Some(found) => return Some(found)
            case None => if (value.items.size < limit) { return Some(JsonSchemaViolation(path, "minItems", "array contains too few items")) }
        }
        case None => ()
    }
    match (jsonSchemaLimit(schema, "maxItems", path)) {
        case Some((limit, error)) => match (error) {
            case Some(found) => return Some(found)
            case None => if (value.items.size > limit) { return Some(JsonSchemaViolation(path, "maxItems", "array contains too many items")) }
        }
        case None => ()
    }
    match (schema.field("items")) {
        case Some(itemSchema) => for (index in 0..value.items.size) {
            match (validateJsonSchemaAt(itemSchema, value.items[index], path + "[" + index.toString() + "]")) {
                case Some(error) => return Some(error)
                case None => ()
            }
        }
        case None => ()
    }
    None
}

func validateJsonString(schema: JsonValue, value: JsonValue, path: String): ?JsonSchemaViolation {
    let length = value.text.toRuneArray().size
    match (jsonSchemaLimit(schema, "minLength", path)) {
        case Some((limit, error)) => match (error) {
            case Some(found) => return Some(found)
            case None => if (length < limit) { return Some(JsonSchemaViolation(path, "minLength", "string is too short")) }
        }
        case None => ()
    }
    match (jsonSchemaLimit(schema, "maxLength", path)) {
        case Some((limit, error)) => match (error) {
            case Some(found) => return Some(found)
            case None => if (length > limit) { return Some(JsonSchemaViolation(path, "maxLength", "string is too long")) }
        }
        case None => ()
    }
    None
}

func jsonSchemaLimit(schema: JsonValue, keyword: String, path: String): ?(Int64, ?JsonSchemaViolation) {
    match (schema.field(keyword)) {
        case None => None
        case Some(value) =>
            if (value.kind != JsonKind.Number) { return Some((0, invalidJsonSchemaValue(path, keyword + " must be a non-negative integer"))) }
            try {
                let parsed = Int64.parse(value.number)
                if (parsed < 0) { Some((0, invalidJsonSchemaValue(path, keyword + " must be a non-negative integer"))) }
                else { Some((parsed, None)) }
            } catch (_: Exception) { Some((0, invalidJsonSchemaValue(path, keyword + " must be a non-negative integer"))) }
    }
}

func jsonSchemaTypeMatches(expected: JsonValue, value: JsonValue): Bool {
    match (expected.kind) {
        case JsonKind.Text => jsonSchemaNamedTypeMatches(expected.text, value)
        case JsonKind.List =>
            for (candidate in expected.items where candidate.kind == JsonKind.Text) {
                if (jsonSchemaNamedTypeMatches(candidate.text, value)) { return true }
            }
            false
        case _ => false
    }
}

func jsonSchemaNamedTypeMatches(expected: String, value: JsonValue): Bool {
    match (expected) {
        case "object" => value.kind == JsonKind.Object
        case "array" => value.kind == JsonKind.List
        case "string" => value.kind == JsonKind.Text
        case "number" => value.kind == JsonKind.Number
        case "integer" => value.kind == JsonKind.Number && !value.number.contains(".") &&
            !value.number.contains("e") && !value.number.contains("E")
        case "boolean" => value.kind == JsonKind.Boolean
        case "null" => value.kind == JsonKind.Null
        case _ => false
    }
}

func jsonSchemaValuesEqual(left: JsonValue, right: JsonValue): Bool {
    if (left.kind != right.kind) { return false }
    match (left.kind) {
        case JsonKind.Null => true
        case JsonKind.Boolean => left.boolean == right.boolean
        case JsonKind.Number => left.number == right.number
        case JsonKind.Text => left.text == right.text
        case JsonKind.List =>
            if (left.items.size != right.items.size) { return false }
            for (index in 0..left.items.size) { if (!jsonSchemaValuesEqual(left.items[index], right.items[index])) { return false } }
            true
        case JsonKind.Object =>
            if (left.fields.size != right.fields.size) { return false }
            for (field in left.fields) {
                match (right.field(field.name)) {
                    case Some(candidate) => if (!jsonSchemaValuesEqual(field.value, candidate)) { return false }
                    case None => return false
                }
            }
            true
    }
}

func jsonSchemaPath(path: String, name: String): String {
    path + "[\"" + name.replace("\\", "\\\\").replace("\"", "\\\"") + "\"]"
}
func invalidJsonSchema(path: String, message: String): ?JsonSchemaViolation {
    Some(JsonSchemaViolation(path, "schema", message))
}
func invalidJsonSchemaValue(path: String, message: String): ?JsonSchemaViolation {
    Some(JsonSchemaViolation(path, "schema", message))
}
