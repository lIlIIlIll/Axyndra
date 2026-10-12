package lsp_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func editTestPosition(line: Int64, character: Int64): JsonNode {
    jsonObject([JsonObjectEntry("line", jsonNumber(line.toString())), JsonObjectEntry("character", jsonNumber(character.toString()))])
}
func editTestRange(start: Int64, end: Int64, replacement: String): JsonNode {
    jsonObject([JsonObjectEntry("range", jsonObject([JsonObjectEntry("start", editTestPosition(0, start)),
        JsonObjectEntry("end", editTestPosition(0, end))])), JsonObjectEntry("newText", jsonString(replacement))])
}
func editTestRejected(action: () -> Unit): Bool {
    try { action(); false } catch (_: Exception) { true }
}
@Test
class WorkspaceEditTests {
    @TestCase
    func utf16RangesKeepMultibyteTextAndRejectSurrogateInterior(): Unit {
        let source = "a😀b\nsecond"
        @Expect(languagePosition(source, editTestPosition(0, 3)), 5)
        @Expect(languagePosition(source, editTestPosition(1, 3)), 10)
        @Expect(languageEditedText(source, jsonArray([editTestRange(1, 3, "emoji")])), "aemojib\nsecond")
        @Expect(editTestRejected({ => let _ = languagePosition(source, editTestPosition(0, 2)) }), true)
        @Expect(editTestRejected({ => let _ = languagePosition(source, editTestPosition(0, 5)) }), true)
    }
    @TestCase
    func descendingEditsRetainOriginalCoordinatesAndRejectOverlap(): Unit {
        @Expect(languageEditedText("abc def ghi", jsonArray([editTestRange(0, 3, "A"), editTestRange(8, 11, "G")])), "A def G")
        @Expect(editTestRejected({ => let _ = languageEditedText("abcdef", jsonArray([editTestRange(0, 4, "x"), editTestRange(3, 5, "y")])) }), true)
        @Expect(editTestRejected({ => let _ = languageEditedText("abcdef", jsonArray([editTestRange(4, 2, "x")])) }), true)
    }
    @TestCase
    func proposalUsesOnlyFrozenDocumentAndNormalizesEncodedRelativePath(): Unit {
        let uri = "file:///workspace/a%20b.py"
        let changes = jsonObject([JsonObjectEntry(uri, jsonArray([editTestRange(0, 3, "new")]))])
        let input = jsonObject([JsonObjectEntry("documents", jsonArray([jsonObject([JsonObjectEntry("uri", jsonString(uri)),
            JsonObjectEntry("text", jsonString("old value"))])]))])
        let proposal = languageFileProposal(jsonObject([JsonObjectEntry("changes", changes)]), input, "file:///workspace/")
        @Expect(text(proposal, "schema"), "axyndra.file-change-proposal/v1")
        let operation = field(proposal, "operations").items[0]
        @Expect(text(operation, "path"), "a b.py")
        @Expect(text(operation, "expected_content"), "old value")
        @Expect(text(operation, "content"), "new value")
        @Expect(proposal.field("source").isNone(), true)
        @Expect(editTestRejected({ => let _ = languageFileProposal(jsonObject([JsonObjectEntry("changes", changes)]),
            jsonObject([JsonObjectEntry("documents", jsonArray([]))]), "file:///workspace") }), true)
    }
    @TestCase
    func uriTraversalForeignAuthorityAndUnfrozenEditFormsCannotMintProposal(): Unit {
        for (uri in ["file:///workspace/%2e%2e/secret", "file:///workspace/a%00b", "file:///workspace/a%5cb", "file://remote/workspace/a", "file:///workspace/%zz"]) {
            @Expect(editTestRejected({ => let _ = languageUriPath(uri) }), true)
        }
        let input = jsonObject([JsonObjectEntry("documents", jsonArray([jsonObject([JsonObjectEntry("uri", jsonString("file:///workspace-other/a")),
            JsonObjectEntry("text", jsonString("old"))])]))])
        let changes = jsonObject([JsonObjectEntry("file:///workspace-other/a", jsonArray([editTestRange(0, 3, "new")]))])
        @Expect(editTestRejected({ => let _ = languageFileProposal(jsonObject([JsonObjectEntry("changes", changes)]), input, "file:///workspace") }), true)
        @Expect(languageFileProposal(jsonObject([JsonObjectEntry("documentChanges", jsonArray([]))]), input, "file:///workspace").unifiedKind == UnifiedJsonKind.Null, true)
    }
    @TestCase
    func equalPositionInsertsKeepArrayOrderBeforeOptionalReplacement(): Unit {
        @Expect(languageEditedText("abc", jsonArray([editTestRange(1, 1, "A"), editTestRange(1, 1, "B")])), "aABbc")
        @Expect(languageEditedText("abc", jsonArray([editTestRange(1, 1, "A"), editTestRange(1, 1, "B"), editTestRange(1, 2, "R")])), "aABRc")
        @Expect(editTestRejected({ => let _ = languageEditedText("abc", jsonArray([editTestRange(1, 2, "R"), editTestRange(1, 1, "A")])) }), true)
    }
    @TestCase
    func versionedDocumentChangesUseExactFrozenVersionAndTakePrecedence(): Unit {
        let input = editVersionedInput(); let edit = editVersionedChange(jsonNumber("7"))
        edit.put("changes", jsonObject([JsonObjectEntry("file:///foreign/ignored", jsonArray([]))]))
        let proposal = languageFileProposal(edit, input, "file:///workspace")
        let operation = field(proposal, "operations").items[0]
        @Expect(text(operation, "path"), "a.py")
        @Expect(text(operation, "expected_content"), "old")
        @Expect(text(operation, "content"), "new")
        @Expect(text(field(languageFileProposal(editVersionedChange(jsonNull()), input, "file:///workspace"), "operations").items[0], "content"), "new")
    }
    @TestCase
    func staleVersionAliasedTargetsAndResourceOperationsCannotPropose(): Unit {
        let input = editVersionedInput()
        for (version in [jsonNumber("6"), jsonNumber("7.0"), jsonString("7")]) {
            @Expect(editTestRejected({ => let _ = languageFileProposal(editVersionedChange(version), input, "file:///workspace") }), true)
        }
        let edit = editVersionedChange(jsonNumber("7")); let original = field(edit, "documentChanges").items[0]
        let alias = jsonObject([JsonObjectEntry("textDocument", jsonObject([JsonObjectEntry("uri", jsonString("file:///workspace/%61.py")),
            JsonObjectEntry("version", jsonNumber("7"))])), JsonObjectEntry("edits", jsonArray([]))])
        edit.put("documentChanges", jsonArray([original, alias]))
        @Expect(editTestRejected({ => let _ = languageFileProposal(edit, input, "file:///workspace") }), true)
        for (kind in ["create", "delete", "rename"]) {
            let resource = jsonObject([JsonObjectEntry("documentChanges", jsonArray([jsonObject([JsonObjectEntry("kind", jsonString(kind)),
                JsonObjectEntry("uri", jsonString("file:///workspace/a.py"))])]))])
            @Expect(editTestRejected({ => let _ = languageFileProposal(resource, input, "file:///workspace") }), true)
        }
    }
    @TestCase
    func emptyAndIdentityEditsReturnNoApplicationPlan(): Unit {
        let input = editVersionedInput()
        for (edit in [jsonNull(), jsonObject([]), jsonObject([JsonObjectEntry("changes", jsonObject([]))]),
            jsonObject([JsonObjectEntry("documentChanges", jsonArray([]))]),
            jsonObject([JsonObjectEntry("changes", jsonObject([JsonObjectEntry("file:///workspace/a.py", jsonArray([editTestRange(0, 3, "old")]))]))])]) {
            @Expect(languageFileProposal(edit, input, "file:///workspace").unifiedKind == UnifiedJsonKind.Null, true)
        }
    }
}

func editVersionedInput(): JsonNode {
    jsonObject([JsonObjectEntry("documents", jsonArray([jsonObject([JsonObjectEntry("uri", jsonString("file:///workspace/a.py")),
        JsonObjectEntry("version", jsonNumber("7")), JsonObjectEntry("text", jsonString("old"))])]))])
}
func editVersionedChange(version: JsonNode): JsonNode {
    jsonObject([JsonObjectEntry("documentChanges", jsonArray([jsonObject([JsonObjectEntry("textDocument", jsonObject([
        JsonObjectEntry("uri", jsonString("file:///workspace/a.py")), JsonObjectEntry("version", version)])),
        JsonObjectEntry("edits", jsonArray([editTestRange(0, 3, "new")]))])]))])
}
