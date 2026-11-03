package agent_product
import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.overflow.*
import yjson.*
import yjson_support.*

func legacyOracle_ensureDirectory(path: String): Unit {
    if (!exists(Path(path))) { Directory.create(path, recursive: true) }
}

func legacyOracle_atomicWrite(path: String, source: String): Result<Unit> {
    var temporary = ""
    try {
        legacyOracle_ensureDirectory(Path(path).parent.toString())
        let file = File.createTemp(Path(path).parent)
        temporary = file.info.path.toString()
        try { file.write(source.toArray()) } finally { file.close() }
        rename(temporary, to: path, overwrite: true)
        Result.Ok(())
    } catch (error: Exception) {
        if (temporary != "") { try { let _ = removeIfExists(temporary) } catch (_: Exception) {} }
        Result.Err(AgentError(
            AgentErrorKind.Internal, "persistence.atomic_write", error.message,
            fields: [ErrorField("path", path)]
        ))
    }
}

func legacyOracle_safeId(value: String): String {
    var safe = value != "" && value != "." && value != ".."
    for (byte in value.toArray()) {
        let alpha = (byte >= UInt8(65) && byte <= UInt8(90)) ||
            (byte >= UInt8(97) && byte <= UInt8(122))
        let digit = byte >= UInt8(48) && byte <= UInt8(57)
        if (!alpha && !digit && byte != UInt8(45) && byte != UInt8(46) && byte != UInt8(95)) {
            safe = false
        }
    }
    if (safe) { return value }
    var hash: UInt64 = 1469598103934665603
    for (byte in value.toArray()) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    "id-" + hash.toString()
}

func legacyOracle_textOr(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func legacyOracle_integerOr(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Number) {
                try {
                    Int64.parse(item.asNumberText())
                } catch (_: Exception) {
                    0
                }
            } else {
                0
            }
        case None => 0
    }
}
