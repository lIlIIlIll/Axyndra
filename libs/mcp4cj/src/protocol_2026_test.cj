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
            roots: Some(McpRootsCapability()),
            sampling: Some(McpSamplingCapability(context: true, tools: true)),
            elicitation: Some(McpElicitationCapability(form: true, url: true)),
            extensions: jsonObject([
                JsonObjectEntry("io.example/client", jsonObject([JsonObjectEntry("enabled", jsonBool(true))]))
            ])
        ).toValue()
        @Expect(client.field("roots").getOrThrow().unifiedKind == UnifiedJsonKind.Object, true)
        @Expect(client.field("sampling").getOrThrow().unifiedKind == UnifiedJsonKind.Object, true)
        @Expect(client.field("sampling").getOrThrow().field("tools").isSome(), true)
        @Expect(client.field("elicitation").getOrThrow().field("url").isSome(), true)
        @Expect(client.field("extensions").getOrThrow().field("io.example/client").getOrThrow().field("enabled").getOrThrow().boolean, true)

        let server = McpServerCapabilities(
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
        @Expect(validateMcpAuthorizationResponseIssuer(
            "", "https://issuer.example", false
        ).isOk(), true)
        @Expect(validateMcpAuthorizationResponseIssuer(
            "", "https://issuer.example", true
        ).isOk(), false)
        @Expect(validateMcpAuthorizationResponseIssuer(
            "https://ISSUER.example", "https://issuer.example", false
        ).isOk(), false)
    }

    @TestCase
    func rejectsExpiredRefreshResultBeforeCaching(): Unit {
        let resource = "https://mcp.example"
        let issuer = "https://auth.example"
        let clientMetadata = McpOAuthClientMetadata("client", ["http://127.0.0.1/callback"])
        let store = MemoryMcpOAuthTokenStore()
        @Expect(store.save(resource, issuer, clientMetadata.clientId, McpOAuthTokenSet(
            "expired-current", expiresAtMillis: Some(1000),
            refreshToken: "refresh-token", scope: ["tools:read"]
        )).isOk(), true)
        let client = McpOAuthClient(
            FixtureOAuthMetadataFetcher(resource, issuer),
            FixtureOAuthRegistration(clientMetadata),
            FixtureOAuthInteraction(),
            FixtureExpiredRefreshExchange(),
            store: store
        )
        match (client.accessToken(resource, ["tools:read"], 1000)) {
            case McpResult.Ok(tokens) => @Expect(tokens.accessToken, "authorized-token")
            case McpResult.Err(error) => @Fail(error.message)
        }
    }

    @TestCase
    func rejectsInsecureOAuthAndAppMetadata() {
        let _ = @ExpectThrows[IllegalArgumentException](McpOAuthClientMetadata("client", ["http://localhost.evil.example/callback"]))
        let _ = @ExpectThrows[IllegalArgumentException](McpProtectedResourceMetadata(
            "https://mcp.example", ["http://issuer.example"]
        ))
        @Expect(validateMcpAppToolMeta(jsonObject([])).isOk(), true)
        @Expect(validateMcpAppToolMeta(jsonObject([
            JsonObjectEntry(MCP_APPS_UI_META, jsonObject([
                JsonObjectEntry("resourceUri", jsonString("ui://example/app")),
                JsonObjectEntry("visibility", jsonArray([
                    jsonString("model"), jsonString("app")
                ]))
            ]))
        ])).isOk(), true)
        @Expect(validateMcpAppToolMeta(jsonObject([
            JsonObjectEntry(MCP_APPS_UI_META, jsonObject([
                JsonObjectEntry("csp", jsonObject([]))
            ]))
        ])).isOk(), false)
        let resource = McpAppResource(
            "ui://example/app", "<html></html>",
            csp: jsonObject([JsonObjectEntry("connectDomains", jsonArray([
                jsonString("https://api.example.com")
            ]))]),
            permissions: jsonObject([JsonObjectEntry("clipboardWrite", jsonObject([]))])
        ).toResourceContent()
        @Expect(validateMcpAppResourceContent(resource).isOk(), true)
        @Expect(resource.field("_meta").getOrThrow().field("ui").isSome(), true)
        @Expect(validateMcpAppResourceContent(jsonObject([
            JsonObjectEntry("uri", jsonString("ui://example/app")),
            JsonObjectEntry("mimeType", jsonString(MCP_APPS_MIME_TYPE)),
            JsonObjectEntry("text", jsonString("<html></html>")),
            JsonObjectEntry("_meta", jsonObject([JsonObjectEntry("ui", jsonObject([
                JsonObjectEntry("domain", jsonString("https://invalid.example"))
            ]))]))
        ])).isOk(), false)
        @Expect(validateMcpAppResourceContent(jsonObject([
            JsonObjectEntry("uri", jsonString("ui://example/app")),
            JsonObjectEntry("mimeType", jsonString(MCP_APPS_MIME_TYPE)),
            JsonObjectEntry("text", jsonString("<html></html>")),
            JsonObjectEntry("_meta", jsonObject([JsonObjectEntry("ui", jsonObject([
                JsonObjectEntry("prefersBorder", jsonString("yes"))
            ]))]))
        ])).isOk(), false)
    }

    @TestCase
    func enforcesTaskStoreIdentityAndTerminalState() {
        let store = MemoryMcpTaskStore()
        let working = McpTask(
            "task-1", McpTaskStatus.Working,
            "2026-08-27T00:00:00Z", "2026-08-27T00:00:00Z", Some(60000)
        )
        @Expect(store.create(working).isOk(), true)
        @Expect(store.create(working).isOk(), false)
        @Expect(store.update(McpTask(
            "task-1", McpTaskStatus.Completed,
            "2026-08-27T00:00:00Z", "2026-08-27T00:01:00Z", Some(60000),
            result: jsonObject([JsonObjectEntry("content", jsonArray([]))])
        )).isOk(), true)
        @Expect(store.update(McpTask(
            "task-1", McpTaskStatus.Working,
            "2026-08-27T00:00:00Z", "2026-08-27T00:02:00Z", Some(60000)
        )).isOk(), false)
        match (store.get("task-1")) {
            case McpResult.Ok(Some(task)) => @Expect(task.status == McpTaskStatus.Completed, true)
            case _ => @Fail("stored MCP task was not found")
        }
    }

    @TestCase
    func enforcesAndDecodesSep2663TaskShapes() {
        let pending = McpTask(
            "task-input", McpTaskStatus.InputRequired,
            "2026-08-27T00:00:00Z", "2026-08-27T00:01:00Z", None,
            inputRequests: jsonObject([JsonObjectEntry("name", jsonObject([
                JsonObjectEntry("method", jsonString(MCP_METHOD_ROOTS_LIST))
            ]))])
        ).toValue()
        @Expect(pending.field("ttlMs").getOrThrow().unifiedKind == UnifiedJsonKind.Null, true)
        @Expect(decodeMcpTask(pending).isOk(), true)
        @Expect(decodeMcpTask(jsonObject([
            JsonObjectEntry("taskId", jsonString("task-input")),
            JsonObjectEntry("status", jsonString("input_required")),
            JsonObjectEntry("createdAt", jsonString("2026-08-27T00:00:00Z")),
            JsonObjectEntry("lastUpdatedAt", jsonString("2026-08-27T00:01:00Z")),
            JsonObjectEntry("ttlMs", jsonNull()),
            JsonObjectEntry("inputRequests", jsonString("malformed"))
        ])).isOk(), false)
        @Expect(decodeMcpTask(jsonObject([
            JsonObjectEntry("taskId", jsonString("task-input")),
            JsonObjectEntry("status", jsonString("input_required")),
            JsonObjectEntry("createdAt", jsonString("2026-08-27T00:00:00Z")),
            JsonObjectEntry("lastUpdatedAt", jsonString("2026-08-27T00:01:00Z")),
            JsonObjectEntry("ttlMs", jsonNull()),
            JsonObjectEntry("inputRequests", jsonObject([
                JsonObjectEntry("bad", jsonObject([JsonObjectEntry("method", jsonString("unknown"))]))
            ]))
        ])).isOk(), false)
        let _ = @ExpectThrows[IllegalArgumentException](McpTask(
            "task-bad", McpTaskStatus.Completed,
            "2026-08-27T00:00:00Z", "2026-08-27T00:01:00Z", None
        ))
        let _ = @ExpectThrows[IllegalArgumentException](McpTask(
            "task-bad", McpTaskStatus.Failed,
            "2026-08-27T00:00:00Z", "2026-08-27T00:01:00Z", None
        ))
    }

    @TestCase
    func constrainsAutomaticInputResolutionRounds() {
        @Expect(McpResolutionPolicy().maxRounds, 10)
        let _ = @ExpectThrows[IllegalArgumentException](McpResolutionPolicy(maxRounds: 0))
        let _ = @ExpectThrows[IllegalArgumentException](McpResolutionPolicy(maxRounds: 11))
    }

    @TestCase
    func rejectsMalformedStandardServerCapabilities() {
        let value = jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("supportedVersions", jsonArray([jsonString(MCP_PROTOCOL_VERSION)])),
            JsonObjectEntry("capabilities", jsonObject([
                JsonObjectEntry("tools", jsonBool(true))
            ])),
            JsonObjectEntry("ttlMs", jsonNumber("300000")),
            JsonObjectEntry("cacheScope", jsonString("private"))
        ])
        @Expect(decodeMcpDiscover(value).isOk(), false)
    }

    @TestCase
    func validatesDeprecatedFeaturesAsTypedMrtrWire() {
        let roots = requireMcpInputRequest(decodeMcpInputRequest(jsonObject([
            JsonObjectEntry("method", jsonString(MCP_METHOD_ROOTS_LIST))
        ])))
        @Expect(decodeMcpInputResponse(roots, jsonObject([JsonObjectEntry("roots", jsonArray([
            jsonObject([JsonObjectEntry("uri", jsonString("file:///workspace"))])
        ]))])).isOk(), true)

        let sampling = requireMcpInputRequest(decodeMcpInputRequest(jsonObject([
            JsonObjectEntry("method", jsonString(MCP_METHOD_SAMPLING_CREATE_MESSAGE)),
            JsonObjectEntry("params", jsonObject([
                JsonObjectEntry("messages", jsonArray([])),
                JsonObjectEntry("maxTokens", jsonNumber("32")),
                JsonObjectEntry("includeContext", jsonString("none"))
            ]))
        ])))
        @Expect(decodeMcpInputResponse(sampling, jsonObject([
            JsonObjectEntry("role", jsonString("assistant")),
            JsonObjectEntry("content", jsonObject([
                JsonObjectEntry("type", jsonString("text")), JsonObjectEntry("text", jsonString("ok"))
            ])),
            JsonObjectEntry("model", jsonString("fixture"))
        ])).isOk(), true)

        let elicitation = requireMcpInputRequest(decodeMcpInputRequest(jsonObject([
            JsonObjectEntry("method", jsonString(MCP_METHOD_ELICITATION_CREATE)),
            JsonObjectEntry("params", jsonObject([
                JsonObjectEntry("mode", jsonString("url")),
                JsonObjectEntry("message", jsonString("Authorize")),
                JsonObjectEntry("url", jsonString("https://example.com/authorize"))
            ]))
        ])))
        @Expect(decodeMcpInputResponse(elicitation, jsonObject([
            JsonObjectEntry("action", jsonString("accept"))
        ])).isOk(), true)
        @Expect(decodeMcpInputRequest(jsonObject([
            JsonObjectEntry("method", jsonString("ping")),
            JsonObjectEntry("params", jsonObject([]))
        ])).isOk(), false)
    }

    @TestCase
    func validatesEnterpriseManagedAuthorizationChain() {
        let metadata = McpAuthorizationServerMetadata(
            "https://auth.example", "https://auth.example/authorize", "https://auth.example/token",
            authorizationGrantProfilesSupported: [MCP_EMA_GRANT_PROFILE]
        )
        let client = McpOAuthClientMetadata("client", ["http://127.0.0.1/callback"])
        let ema = McpEnterpriseManagedAuthorization(FixtureIdentityExchange(), FixtureResourceExchange())
        match (ema.accessToken(
            McpEnterpriseIdentity("https://idp.example", "id-token"), metadata, client,
            "https://mcp.example", ["tools:read"], 1000
        )) {
            case McpResult.Ok(tokens) => @Expect(tokens.accessToken, "access-token")
            case McpResult.Err(error) => @Fail(error.message)
        }
        let unsupported = McpAuthorizationServerMetadata(
            "https://auth.example", "https://auth.example/authorize", "https://auth.example/token"
        )
        @Expect(ema.accessToken(
            McpEnterpriseIdentity("https://idp.example", "id-token"), unsupported, client,
            "https://mcp.example", ["tools:read"], 1000
        ).isOk(), false)
    }
}

func requireMcpInputRequest(value: McpResult<McpInputRequest>): McpInputRequest {
    match (value) {
        case McpResult.Ok(found) => found
        case McpResult.Err(error) => throw error
    }
}

class FixtureOAuthMetadataFetcher <: McpOAuthMetadataFetcher {
    let resource: String
    let issuer: String
    init(resource: String, issuer: String) { this.resource = resource; this.issuer = issuer }
    public func protectedResource(resource: String): McpResult<McpProtectedResourceMetadata> {
        McpResult.Ok(McpProtectedResourceMetadata(resource, [issuer]))
    }
    public func authorizationServer(issuer: String): McpResult<McpAuthorizationServerMetadata> {
        McpResult.Ok(McpAuthorizationServerMetadata(
            issuer, issuer + "/authorize", issuer + "/token",
            codeChallengeMethodsSupported: ["S256"]
        ))
    }
}

class FixtureOAuthRegistration <: McpOAuthClientRegistration {
    let client: McpOAuthClientMetadata
    init(client: McpOAuthClientMetadata) { this.client = client }
    public func clientMetadataDocument(_: String): McpResult<?McpOAuthClientMetadata> {
        McpResult.Ok(None)
    }
    public func preRegistered(_: String): McpResult<?McpOAuthClientMetadata> {
        McpResult.Ok(Some(client))
    }
    public func dynamicRegister(_: McpAuthorizationServerMetadata): McpResult<McpOAuthClientMetadata> {
        McpResult.Ok(client)
    }
}

class FixtureOAuthInteraction <: McpOAuthAuthorizationInteraction {
    public func authorize(
        _: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        _: String,
        _: Array<String>
    ): McpResult<McpPkceAuthorizationGrant> {
        McpResult.Ok(McpPkceAuthorizationGrant(
            "authorization-code", client.redirectUris[0],
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ", ""
        ))
    }
}

class FixtureExpiredRefreshExchange <: McpOAuthTokenExchange {
    public func exchangeAuthorizationCode(
        _: McpAuthorizationServerMetadata,
        _: McpOAuthClientMetadata,
        _: String,
        _: String,
        _: String,
        _: String
    ): McpResult<McpOAuthTokenSet> {
        McpResult.Ok(McpOAuthTokenSet(
            "authorized-token", expiresAtMillis: Some(100000), scope: ["tools:read"]
        ))
    }
    public func refresh(
        _: McpAuthorizationServerMetadata,
        _: McpOAuthClientMetadata,
        _: String,
        _: String,
        _: Array<String>
    ): McpResult<McpOAuthTokenSet> {
        McpResult.Ok(McpOAuthTokenSet(
            "expired-refresh", expiresAtMillis: Some(1010), scope: ["tools:read"]
        ))
    }
}

class FixtureIdentityExchange <: McpEnterpriseIdentityExchange {
    public func exchangeIdentity(
        identity: McpEnterpriseIdentity, audience: String, resource: String, scopes: Array<String>
    ): McpResult<McpIdentityAssertionGrant> {
        McpResult.Ok(McpIdentityAssertionGrant(
            "id-jag", identity.issuer, "subject", audience, resource, "client", 2000, scopes: scopes
        ))
    }
}

class FixtureResourceExchange <: McpEnterpriseResourceExchange {
    public func exchangeAssertion(
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        assertion: String
    ): McpResult<McpOAuthTokenSet> {
        let _ = metadata; let _ = client
        if (assertion != "id-jag") { return authenticationMcpFailure<McpOAuthTokenSet>("fixture", "bad assertion") }
        McpResult.Ok(McpOAuthTokenSet("access-token", scope: ["tools:read"]))
    }
}
