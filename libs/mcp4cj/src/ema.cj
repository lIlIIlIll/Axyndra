package mcp4cj

import yjson.*
import yjson_support.*

public let MCP_EMA_EXTENSION = "io.modelcontextprotocol/enterprise-managed-authorization"
public let MCP_EMA_GRANT_PROFILE = "urn:ietf:params:oauth:grant-profile:id-jag"
public let MCP_EMA_TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
public let MCP_EMA_ID_JAG_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id-jag"
public let MCP_EMA_ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token"
public let MCP_EMA_JWT_BEARER_GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer"

public class McpEnterpriseIdentity {
    public let issuer: String
    public let subjectToken: String
    public let subjectTokenType: String
    public init(issuer: String, subjectToken: String, subjectTokenType!: String = MCP_EMA_ID_TOKEN_TYPE) {
        if (!secureMcpMetadataUrl(issuer) || subjectToken.trimAscii() == "" || subjectTokenType.trimAscii() == "") {
            throw IllegalArgumentException("enterprise identity requires secure issuer and subject token")
        }
        this.issuer = issuer; this.subjectToken = subjectToken; this.subjectTokenType = subjectTokenType
    }
}

public class McpIdentityAssertionGrant {
    public let assertion: String
    public let issuer: String
    public let subject: String
    public let audience: String
    public let resource: String
    public let clientId: String
    public let scopes: Array<String>
    public let expiresAtMillis: Int64
    public let claims: JsonNode
    public init(
        assertion: String, issuer: String, subject: String, audience: String,
        resource: String, clientId: String, expiresAtMillis: Int64,
        scopes!: Array<String> = [], claims!: JsonNode = jsonObject([])
    ) {
        if (assertion.trimAscii() == "" || !secureMcpMetadataUrl(issuer) || subject.trimAscii() == "" ||
            !secureMcpMetadataUrl(audience) || !secureMcpMetadataUrl(resource) || clientId.trimAscii() == "" ||
            expiresAtMillis <= 0) {
            throw IllegalArgumentException("invalid enterprise identity assertion grant")
        }
        requireObject(claims, "enterprise identity assertion claims")
        this.assertion = assertion; this.issuer = issuer; this.subject = subject
        this.audience = audience; this.resource = resource; this.clientId = clientId
        this.expiresAtMillis = expiresAtMillis; this.scopes = scopes; this.claims = claims
    }
}

public interface McpEnterpriseIdentityExchange {
    // RFC 8693 exchange at the enterprise IdP. `audience` is the resource
    // authorization-server issuer; resource is the MCP protected resource.
    func exchangeIdentity(
        identity: McpEnterpriseIdentity,
        audience: String,
        resource: String,
        scopes: Array<String>
    ): McpResult<McpIdentityAssertionGrant>
}

public interface McpEnterpriseResourceExchange {
    // RFC 7523 JWT bearer grant at the resource authorization server.
    func exchangeAssertion(
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        assertion: String
    ): McpResult<McpOAuthTokenSet>
}

public class McpEnterpriseManagedAuthorization {
    private let identityExchange: McpEnterpriseIdentityExchange
    private let resourceExchange: McpEnterpriseResourceExchange
    public init(
        identityExchange: McpEnterpriseIdentityExchange,
        resourceExchange: McpEnterpriseResourceExchange
    ) {
        this.identityExchange = identityExchange; this.resourceExchange = resourceExchange
    }

    public func accessToken(
        identity: McpEnterpriseIdentity,
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        resource: String,
        scopes: Array<String>,
        nowMillis: Int64
    ): McpResult<McpOAuthTokenSet> {
        if (!metadata.supportsGrantProfile(MCP_EMA_GRANT_PROFILE)) {
            return authenticationMcpFailure<McpOAuthTokenSet>(
                "mcp.ema.profile_unsupported", "authorization server does not advertise the ID-JAG grant profile"
            )
        }
        let grant = match (identityExchange.exchangeIdentity(identity, metadata.issuer, resource, scopes)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (grant.issuer != identity.issuer || grant.audience != metadata.issuer || grant.resource != resource ||
            grant.clientId != client.clientId || nowMillis >= grant.expiresAtMillis || !mcpScopesCover(grant.scopes, scopes)) {
            return authorizationMcpFailure<McpOAuthTokenSet>(
                "mcp.ema.assertion_invalid", "ID-JAG claims do not match the enterprise authorization request"
            )
        }
        let exchanged = match (resourceExchange.exchangeAssertion(metadata, client, grant.assertion)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        let tokens = if (exchanged.scope.isEmpty()) {
            McpOAuthTokenSet(
                exchanged.accessToken,
                tokenType: exchanged.tokenType,
                expiresAtMillis: exchanged.expiresAtMillis,
                refreshToken: exchanged.refreshToken,
                scope: grant.scopes
            )
        } else { exchanged }
        if (tokens.expired(nowMillis)) {
            return authenticationMcpFailure<McpOAuthTokenSet>(
                "mcp.ema.token_expired", "enterprise access token is already expired"
            )
        }
        if (!tokens.covers(scopes)) {
            return authorizationMcpFailure<McpOAuthTokenSet>(
                "mcp.ema.scope_required", "enterprise access token omitted a requested scope"
            )
        }
        McpResult.Ok(tokens)
    }
}

func mcpScopesCover(granted: Array<String>, required: Array<String>): Bool {
    for (needed in required) {
        var found = false
        for (value in granted where value == needed) { found = true; break }
        if (!found) { return false }
    }
    true
}
