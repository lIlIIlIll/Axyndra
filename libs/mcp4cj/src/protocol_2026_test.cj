package mcp4cj

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class McpProtocol2026Tests {
    @TestCase
    func preservesTypedCapabilityExtensions() {
        let client = McpClientCapabilities(
            roots: Some(McpCapabilityFeature(listChanged: true)),
            sampling: true,
            extensions: jsonObject([
                JsonObjectEntry("io.example/client", jsonObject([JsonObjectEntry("enabled", jsonBool(true))]))
            ])
        ).toValue()
        @Expect(client.field("roots").getOrThrow().field("listChanged").getOrThrow().boolean, true)
        @Expect(client.field("sampling").getOrThrow().unifiedKind == UnifiedJsonKind.Object, true)
        @Expect(client.field("io.example/client").getOrThrow().field("enabled").getOrThrow().boolean, true)

        let server = McpServerCapabilities2026(
            completion: true,
            prompts: Some(McpCapabilityFeature(listChanged: true)),
            resources: Some(McpCapabilityFeature(subscribe: true)),
            tools: Some(McpCapabilityFeature(listChanged: true))
        ).toValue()
        @Expect(server.field("completions").getOrThrow().unifiedKind == UnifiedJsonKind.Object, true)
        @Expect(server.field("resources").getOrThrow().field("subscribe").getOrThrow().boolean, true)
    }

    @TestCase
    func serializesPromptResourceAndPageContracts() {
        let prompt = McpPrompt("review", arguments: [McpPromptArgument("topic", required: true)]).toValue()
        @Expect(prompt.field("arguments").getOrThrow().items[0].field("required").getOrThrow().boolean, true)

        let resource = McpResource("file:///tmp/readme", "readme", size: Some(12)).toValue()
        @Expect(resource.field("size").getOrThrow().number, "12")

        let page = McpPage([resource], nextCursor: "next", ttlMillis: 100, cacheScope: "private").toValue("resources")
        @Expect(page.field("resultType").getOrThrow().text, MCP_RESULT_COMPLETE)
        @Expect(page.field("resources").getOrThrow().items.size, 1)
        @Expect(page.field("nextCursor").getOrThrow().text, "next")
    }

    @TestCase
    func validatesOAuthIssuerAudienceExpiryAndScope() {
        let claims = McpTokenClaims(
            "subject", "https://issuer.example", ["https://mcp.example"],
            scopes: ["tools:read"], expiresAtMillis: Some(2000)
        )
        @Expect(validateMcpTokenClaims(
            claims, "https://issuer.example", "https://mcp.example", ["tools:read"], 1000
        ).isOk(), true)
        @Expect(validateMcpTokenClaims(
            claims, "https://other.example", "https://mcp.example", ["tools:read"], 1000
        ).isOk(), false)
        @Expect(validateMcpTokenClaims(
            claims, "https://issuer.example", "https://mcp.example", ["tools:write"], 1000
        ).isOk(), false)
        @Expect(validateMcpTokenClaims(
            claims, "https://issuer.example", "https://mcp.example", ["tools:read"], 2000
        ).isOk(), false)
    }

    @TestCase
    func rejectsInsecureOAuthAndAppMetadata() {
        let _ = @ExpectThrows[IllegalArgumentException](McpOAuthClientMetadata("client", ["http://localhost.evil.example/callback"]))
        let _ = @ExpectThrows[IllegalArgumentException](McpProtectedResourceMetadata(
            "https://mcp.example", ["http://issuer.example"]
        ))
        @Expect(validateMcpAppToolMeta(jsonObject([])).isOk(), false)
        @Expect(validateMcpAppToolMeta(jsonObject([
            JsonObjectEntry(MCP_APPS_RESOURCE_URI_META, jsonString("ui://example/app")),
            JsonObjectEntry(MCP_APPS_VISIBILITY_META, jsonArray([
                jsonString("model"), jsonString("app")
            ]))
        ])).isOk(), true)
    }

    @TestCase
    func enforcesTaskStoreIdentityAndTerminalState() {
        let store = MemoryMcpTaskStore()
        let working = McpTask("task-1", McpTaskStatus.Working)
        @Expect(store.create(working).isOk(), true)
        @Expect(store.create(working).isOk(), false)
        @Expect(store.update(McpTask("task-1", McpTaskStatus.Completed)).isOk(), true)
        @Expect(store.update(McpTask("task-1", McpTaskStatus.Working)).isOk(), false)
        match (store.get("task-1")) {
            case McpResult.Ok(Some(task)) => @Expect(task.status == McpTaskStatus.Completed, true)
            case _ => @Fail("stored MCP task was not found")
        }
        @Expect(store.list("", 10).isOk(), true)
        @Expect(store.remove("task-1").isOk(), true)
        match (store.get("task-1")) {
            case McpResult.Ok(None) => ()
            case _ => @Fail("removed MCP task is still present")
        }
    }

    @TestCase
    func constrainsAutomaticInputResolutionRounds() {
        @Expect(McpResolutionPolicy().maxRounds, 10)
        let _ = @ExpectThrows[IllegalArgumentException](McpResolutionPolicy(maxRounds: 0))
        let _ = @ExpectThrows[IllegalArgumentException](McpResolutionPolicy(maxRounds: 11))
    }
}
