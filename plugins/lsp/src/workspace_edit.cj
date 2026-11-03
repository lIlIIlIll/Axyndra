package lsp_plugin

import std.collection.*
import yjson.*
import yjson_support.*

// Pure in-memory translation of an LSP WorkspaceEdit. The UTF-16/range and
// descending non-overlap rules are moved from Product's old LSP implementation;
// filesystem reads, writes and synthetic callback contexts are not copied.
class LanguageTextEdit {
    let start: Int64; let end: Int64; let replacement: String
    init(start: Int64, end: Int64, replacement: String) { this.start = start; this.end = end; this.replacement = replacement }
}
func languagePosition(content: String, position: JsonNode): Int64 {
    exact(position, ["line", "character"])
    let targetLine = number(position, "line"); let targetCharacter = number(position, "character")
    require(targetLine >= 0 && targetCharacter >= 0, "lsp_plugin.edit_position")
    var line: Int64 = 0; var character: Int64 = 0; var offset: Int64 = 0
    for (rune in content.runes()) {
        if (line == targetLine && character == targetCharacter) { return offset }
        let bytes = rune.toString().size
        if (rune == r'\n') {
            require(line != targetLine, "lsp_plugin.edit_position")
            line += 1; character = 0
        } else { character += if (bytes == 4) { 2 } else { 1 } }
        offset += bytes
    }
    require(line == targetLine && character == targetCharacter, "lsp_plugin.edit_position")
    offset
}
func languageEditedText(content: String, edits: JsonNode): String {
    require(edits.unifiedKind == UnifiedJsonKind.List && edits.items.size <= 1024, "lsp_plugin.edit_limit")
    let planned = ArrayList<LanguageTextEdit>()
    for (edit in edits.items) {
        exact(edit, ["range", "newText"])
        let range = field(edit, "range"); exact(range, ["start", "end"])
        require(field(edit, "newText").unifiedKind == UnifiedJsonKind.Text, "lsp_plugin.edit_shape")
        let start = languagePosition(content, field(range, "start")); let end = languagePosition(content, field(range, "end"))
        require(end >= start, "lsp_plugin.edit_position")
        planned.add(LanguageTextEdit(start, end, text(edit, "newText")))
    }
    let remaining = ArrayList<LanguageTextEdit>(planned.toArray()); var result = content; var previous = content.size
    while (!remaining.isEmpty()) {
        // Apply equal-position edits in reverse input order so adjacent
        // inserts keep their specified order in the resulting document.
        var largest: Int64 = 0
        for (index in 1..remaining.size where remaining[index].start >= remaining[largest].start) { largest = index }
        let edit = remaining.remove(at: largest)
        require(edit.end <= previous, "lsp_plugin.overlapping_edits")
        result = result[..edit.start] + edit.replacement + result[edit.end..]; previous = edit.start
        require(result.size <= 1048576, "lsp_plugin.edit_limit")
    }
    result
}
func languageUriPath(uri: String): String {
    require(uri.startsWith("file:///") && !uri.contains("?") && !uri.contains("#"), "lsp_plugin.edit_uri")
    let source = uri[7..].toArray(); let bytes = ArrayList<Byte>(); var index: Int64 = 0
    while (index < source.size) {
        if (source[index] == b'%') {
            require(index + 2 < source.size, "lsp_plugin.edit_uri")
            let high = languageHex(source[index + 1]); let low = languageHex(source[index + 2])
            bytes.add(UInt8(high * 16 + low)); index += 3
        } else { bytes.add(source[index]); index += 1 }
    }
    let path = String.fromUtf8(bytes.toArray())
    require(!path.contains("\u{0000}") && !path.contains("\\"), "lsp_plugin.edit_uri")
    for (part in path.split("/") where part == "." || part == "..") { throw PluginFailure("lsp_plugin.edit_uri") }
    path
}
func languageHex(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value - b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value - b'A') + 10 }
    throw PluginFailure("lsp_plugin.edit_uri")
}
func languageFileProposal(edit: JsonNode, input: JsonNode, rootUri: String): JsonNode {
    if (edit.unifiedKind == UnifiedJsonKind.Null) { return jsonNull() }
    require(edit.unifiedKind == UnifiedJsonKind.Object, "lsp_plugin.edit_shape")
    for (entry in edit.fields) {
        require(entry.name == "changes" || entry.name == "documentChanges", "lsp_plugin.edit_shape")
    }
    let changes = ArrayList<JsonNode>()
    match (edit.field("documentChanges")) {
        case Some(entries) =>
            require(entries.unifiedKind == UnifiedJsonKind.List && entries.items.size <= 32, "lsp_plugin.edit_shape")
            for (entry in entries.items) {
                // Resource operations and annotated edits require their own
                // reviewed Host plans; accepting text edits does not grant them.
                exact(entry, ["textDocument", "edits"])
                let identifier = field(entry, "textDocument"); exact(identifier, ["uri", "version"])
                let version = field(identifier, "version")
                require(field(identifier, "uri").unifiedKind == UnifiedJsonKind.Text &&
                    (version.unifiedKind == UnifiedJsonKind.Null ||
                        (version.unifiedKind == UnifiedJsonKind.Number && number(identifier, "version") > 0 &&
                            version.asNumberText() == number(identifier, "version").toString())), "lsp_plugin.edit_version")
                changes.add(jsonObject([JsonObjectEntry("uri", field(identifier, "uri")),
                    JsonObjectEntry("version", version), JsonObjectEntry("edits", field(entry, "edits"))]))
            }
        case None =>
            match (edit.field("changes")) {
                case Some(entries) =>
                    require(entries.unifiedKind == UnifiedJsonKind.Object && entries.fields.size <= 32, "lsp_plugin.edit_shape")
                    for (entry in entries.fields) {
                        changes.add(jsonObject([JsonObjectEntry("uri", jsonString(entry.name)),
                            JsonObjectEntry("version", jsonNull()), JsonObjectEntry("edits", entry.value)]))
                    }
                case None => ()
            }
    }
    if (changes.isEmpty()) { return jsonNull() }
    let documents = field(input, "documents")
    require(documents.unifiedKind == UnifiedJsonKind.List && documents.items.size <= 16, "lsp_plugin.edit_document_not_frozen")
    let operations = ArrayList<JsonNode>(); let root = languageUriPath(rootUri)
    let prefix = if (root.endsWith("/")) { root } else { root + "/" }
    let paths = HashSet<String>()
    for (change in changes) {
        let uri = text(change, "uri"); let path = languageUriPath(uri)
        require(path.startsWith(prefix) && path.size > prefix.size, "lsp_plugin.edit_outside_workspace")
        require(!paths.contains(path), "lsp_plugin.edit_duplicate_document"); paths.add(path)
        var original: ?String = None
        for (document in documents.items where text(document, "uri") == uri) {
            require(original.isNone() && field(document, "text").unifiedKind == UnifiedJsonKind.Text, "lsp_plugin.edit_document_not_frozen")
            let version = field(change, "version")
            require(version.unifiedKind == UnifiedJsonKind.Null ||
                (field(document, "version").unifiedKind == UnifiedJsonKind.Number &&
                    version.asNumberText() == field(document, "version").asNumberText()), "lsp_plugin.edit_version_stale")
            original = Some(text(document, "text"))
        }
        require(original.isSome(), "lsp_plugin.edit_document_not_frozen")
        let updated = languageEditedText(original.getOrThrow(), field(change, "edits"))
        if (updated == original.getOrThrow()) { continue }
        operations.add(jsonObject([JsonObjectEntry("kind", jsonString("replace")), JsonObjectEntry("path", jsonString(path[prefix.size..])),
            JsonObjectEntry("expected_content", jsonString(original.getOrThrow())), JsonObjectEntry("content", jsonString(updated))]))
    }
    if (operations.isEmpty()) { return jsonNull() }
    let proposal = jsonObject([JsonObjectEntry("schema", jsonString("axyndra.file-change-proposal/v1")), JsonObjectEntry("operations", jsonArray(operations.toArray()))])
    require(stringifyUnifiedJson(proposal).size <= 65536, "lsp_plugin.file_proposal_limit")
    proposal
}
