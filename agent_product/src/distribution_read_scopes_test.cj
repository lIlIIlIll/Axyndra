package agent_product

import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func codingFixtureReadScopeDefaults(fixture: CodingDistributionFixture): Unit {
    let path = fixture.bundle + "/distribution.json"
    let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
    // The exact shipped recipe; no special fixture path or permission branch.
    manifest.put("read_scopes", parseUnifiedJson(String.fromUtf8(File.readFrom("profiles/coding-read-scopes.json"))))
    File.writeTo(path, stringifyUnifiedJson(manifest).toArray())
}

@Test
class CodingReadScopeDefaultsTests {
    @TestCase
    func codingReadsManagedSkillsOnlyAfterOperatorSelectsThem(): Unit {
        let f = CodingDistributionFixture()
        try {
            codingFixtureReadScopeDefaults(f)
            writeObservedSkill(f.root + "/settings/managed-skills", "SEEDED-CONTEXT-DATA")
            writeObservedSkill(f.root + "/workspace/.omp/skills", "DEFAULT-WORKSPACE-DATA")
            let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
            try {
                let path = f.root + "/settings/plugins/read-scopes.json"
                let contents = String.fromUtf8(File.readFrom(path))
                @Expect(canonicalAgentValue(parseUnifiedJson(contents)),
                    canonicalAgentValue(parseUnifiedJson(String.fromUtf8(File.readFrom("profiles/coding-read-scopes.json")))))
                let host = product.vnext.javascriptPlugins
                let scopes = lifecycleTestRequire(host.captureContextReadScopes())
                @Expect(scopes.permission(host, f.root + "/settings/managed-skills", "outside-workspace.read"), "sensitive-path.read")
                @Expect(scopes.permission(host, f.root + "/settings/managed-skills/credentials", "outside-workspace.read"), "sensitive-path.read")
                @Expect(product.applicationSession().submit("$review").isOk())
                let initial = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
                @Expect(initial.contains("DEFAULT-WORKSPACE-DATA"))
                @Expect(!initial.contains("SEEDED-CONTEXT-DATA"))
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(String.fromUtf8(File.readFrom(path)), contents)
                let database = SqliteDatabase(f.root + "/state/state.db")
                try {
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") >= 2)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
                } finally { database.close() }
                let selectionPath = f.root + "/settings/plugins/context.json"
                let selection = parseUnifiedJson(String.fromUtf8(File.readFrom(selectionPath)))
                let resource = selection.field("resources").getOrThrow().items[0]
                resource.put("source", textValue("$" + "{settings_root}/managed-skills"))
                resource.put("path", textValue("managed"))
                selection.field("query").getOrThrow().put("resource_roots", listValue([textValue("managed")]))
                let operatorSelection = stringifyUnifiedJson(selection)
                let operatorScopes = "{\"version\":1,\"roots\":[\"" + "$" + "{settings_root}/managed-skills\"]}"
                File.writeTo(selectionPath, operatorSelection.toArray())
                File.writeTo(path, operatorScopes.toArray())
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(String.fromUtf8(File.readFrom(selectionPath)), operatorSelection)
                @Expect(String.fromUtf8(File.readFrom(path)), operatorScopes)
                let configured = lifecycleTestRequire(host.captureContextReadScopes())
                @Expect(configured.permission(host, f.root + "/settings/managed-skills", "outside-workspace.read"), "outside-workspace.read")
                @Expect(configured.permission(host, f.root + "/settings/managed-skills/credentials", "outside-workspace.read"), "sensitive-path.read")
                @Expect(product.applicationSession().submit("$review").isOk())
                @Expect(product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("SEEDED-CONTEXT-DATA"))
            } finally { let _ = product.close() }
        } finally { f.close() }
    }

    @TestCase
    func explicitInvalidOrEmptyReadScopeFileIsNeverOverwritten(): Unit {
        for (contents in ["{not-valid-json", "{\"version\":1,\"roots\":[]}"]) {
            let f = CodingDistributionFixture()
            try {
                codingFixtureReadScopeDefaults(f)
                Directory.create(f.root + "/workspace")
                Directory.create(f.root + "/settings/plugins", recursive: true)
                let path = f.root + "/settings/plugins/read-scopes.json"
                File.writeTo(path, contents.toArray())
                let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
                try {
                    @Expect(String.fromUtf8(File.readFrom(path)), contents)
                    @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                    @Expect(String.fromUtf8(File.readFrom(path)), contents)
                    if (contents == "{not-valid-json") {
                        @Expect(product.vnext.javascriptPlugins.captureContextReadScopes().isError()) }
                    let database = SqliteDatabase(f.root + "/state/state.db")
                    try { @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0) }
                    finally { database.close() }
                } finally { let _ = product.close() }
            } finally { f.close() }
        }
    }
}
