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
    func normalCodingOpenSeedsMissingDataRootsAndUsesCanonicalApprovedReads(): Unit {
        let f = CodingDistributionFixture()
        try {
            codingFixtureReadScopeDefaults(f)
            writeObservedSkill(f.root + "/settings/managed-skills", "SEEDED-CONTEXT-DATA")
            Directory.create(f.root + "/workspace")
            let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
            try {
                let path = f.root + "/settings/plugins/read-scopes.json"
                let contents = String.fromUtf8(File.readFrom(path))
                @Expect(canonicalAgentValue(parseUnifiedJson(contents)),
                    canonicalAgentValue(parseUnifiedJson(String.fromUtf8(File.readFrom("profiles/coding-read-scopes.json")))))
                let host = product.vnext.javascriptPlugins
                let scopes = lifecycleTestRequire(host.captureContextReadScopes())
                @Expect(scopes.permission(host, f.root + "/settings/managed-skills", "outside-workspace.read"), "outside-workspace.read")
                @Expect(scopes.permission(host, f.root + "/settings/managed-skills/credentials", "outside-workspace.read"), "sensitive-path.read")
                @Expect(product.applicationSession().submit("$review").isOk())
                @Expect(product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("SEEDED-CONTEXT-DATA"))
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(String.fromUtf8(File.readFrom(path)), contents)
                let database = SqliteDatabase(f.root + "/state/state.db")
                try {
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") >= 2)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
                } finally { database.close() }
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
