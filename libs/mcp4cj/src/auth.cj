package mcp4cj

import yjson.*
import yjson_support.*
import std.collection.*

public class McpProtectedResourceMetadata {
    public let resource: String
    public let authorizationServers: Array<String>
    public let scopesSupported: Array<String>
    public let bearerMethodsSupported: Array<String>
    public init(
        resource: String,
        authorizationServers: Array<String>,
        scopesSupported!: Array<String> = [],
        bearerMethodsSupported!: Array<String> = ["header"]
    ) {
        if (!secureMcpMetadataUrl(resource) || authorizationServers.isEmpty()) {
            throw IllegalArgumentException("MCP protected resource metadata requires secure resource and authorization server URLs")
        }
        for (issuer in authorizationServers where !secureMcpMetadataUrl(issuer)) {
            throw IllegalArgumentException("MCP authorization server URL must be secure")
        }
        this.resource = resource; this.authorizationServers = authorizationServers
        this.scopesSupported = scopesSupported; this.bearerMethodsSupported = bearerMethodsSupported
    }
}

public class McpAuthorizationServerMetadata {
    public let issuer: String
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let registrationEndpoint: String
    public let codeChallengeMethodsSupported: Array<String>
    public init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint!: String = "",
        codeChallengeMethodsSupported!: Array<String> = []
    ) {
        if (!secureMcpMetadataUrl(issuer) || !secureMcpMetadataUrl(authorizationEndpoint) || !secureMcpMetadataUrl(tokenEndpoint)) {
            throw IllegalArgumentException("MCP authorization metadata endpoints must use HTTPS or loopback HTTP")
        }
        if (registrationEndpoint != "" && !secureMcpMetadataUrl(registrationEndpoint)) {
            throw IllegalArgumentException("MCP registration endpoint must be secure")
        }
        this.issuer = issuer; this.authorizationEndpoint = authorizationEndpoint
        this.tokenEndpoint = tokenEndpoint; this.registrationEndpoint = registrationEndpoint
        this.codeChallengeMethodsSupported = codeChallengeMethodsSupported
    }

    public func supportsS256(): Bool {
        for (method in codeChallengeMethodsSupported where method == "S256") { return true }
        false
    }
}

public class McpOAuthClientMetadata {
    public let clientId: String
    public let redirectUris: Array<String>
    public let clientName: String
    public let tokenEndpointAuthMethod: String
    public init(
        clientId: String,
        redirectUris: Array<String>,
        clientName!: String = "mcp4cj",
        tokenEndpointAuthMethod!: String = "none"
    ) {
        if (clientId.trimAscii() == "" || redirectUris.isEmpty()) { throw IllegalArgumentException("MCP OAuth client metadata requires clientId and redirectUris") }
        for (uri in redirectUris where !secureMcpRedirectUri(uri)) { throw IllegalArgumentException("MCP OAuth redirect URI is not secure") }
        this.clientId = clientId; this.redirectUris = redirectUris; this.clientName = clientName
        this.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    }
}

public class McpOAuthTokenSet {
    public let accessToken: String
    public let tokenType: String
    public let expiresAtMillis: ?Int64
    public let refreshToken: String
    public let scope: Array<String>
    public init(
        accessToken: String,
        tokenType!: String = "Bearer",
        expiresAtMillis!: ?Int64 = None,
        refreshToken!: String = "",
        scope!: Array<String> = []
    ) {
        if (accessToken.trimAscii() == "" || tokenType.toAsciiLower() != "bearer") {
            throw IllegalArgumentException("MCP OAuth token set requires a bearer access token")
        }
        this.accessToken = accessToken; this.tokenType = tokenType; this.expiresAtMillis = expiresAtMillis
        this.refreshToken = refreshToken; this.scope = scope
    }
    public func expired(nowMillis: Int64, skewMillis!: Int64 = 30000): Bool {
        match (expiresAtMillis) { case Some(value) => nowMillis + max(skewMillis, 0) >= value; case None => false }
    }
    public func covers(required: Array<String>): Bool {
        for (needed in required) {
            var found = false
            for (granted in scope where granted == needed) { found = true; break }
            if (!found) { return false }
        }
        true
    }
}

public class McpTokenClaims {
    public let subject: String
    public let issuer: String
    public let audience: Array<String>
    public let scopes: Array<String>
    public let expiresAtMillis: ?Int64
    public let claims: JsonNode
    public init(
        subject: String,
        issuer: String,
        audience: Array<String>,
        scopes!: Array<String> = [],
        expiresAtMillis!: ?Int64 = None,
        claims!: JsonNode = jsonObject([])
    ) {
        if (subject.trimAscii() == "" || issuer.trimAscii() == "" || audience.isEmpty()) { throw IllegalArgumentException("MCP token claims require subject, issuer, and audience") }
        requireObject(claims, "MCP token claims")
        this.subject = subject; this.issuer = issuer; this.audience = audience; this.scopes = scopes
        this.expiresAtMillis = expiresAtMillis; this.claims = claims
    }
}

public interface McpAccessTokenVerifier {
    func verify(accessToken: String, resource: String, nowMillis: Int64): McpResult<McpTokenClaims>
}

public interface McpOAuthMetadataFetcher {
    func protectedResource(resource: String): McpResult<McpProtectedResourceMetadata>
    func authorizationServer(issuer: String): McpResult<McpAuthorizationServerMetadata>
}

public interface McpOAuthClientRegistration {
    func clientMetadataDocument(issuer: String): McpResult<?McpOAuthClientMetadata>
    func preRegistered(issuer: String): McpResult<?McpOAuthClientMetadata>
    func dynamicRegister(metadata: McpAuthorizationServerMetadata): McpResult<McpOAuthClientMetadata>
}

public interface McpOAuthTokenExchange {
    func exchangeAuthorizationCode(
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        code: String,
        redirectUri: String,
        codeVerifier: String,
        resource: String
    ): McpResult<McpOAuthTokenSet>
    func refresh(
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        refreshToken: String,
        resource: String,
        scopes: Array<String>
    ): McpResult<McpOAuthTokenSet>
}

public func validateMcpTokenClaims(
    claims: McpTokenClaims,
    expectedIssuer: String,
    resource: String,
    requiredScopes: Array<String>,
    nowMillis: Int64
): McpResult<Unit> {
    if (claims.issuer != expectedIssuer) { return authorizationMcpFailure<Unit>("mcp.oauth_issuer_mismatch", "access token issuer does not match authorization server") }
    var audience = false
    for (value in claims.audience where value == resource) { audience = true; break }
    if (!audience) { return authorizationMcpFailure<Unit>("mcp.oauth_audience_mismatch", "access token is not intended for this MCP resource") }
    match (claims.expiresAtMillis) { case Some(value) => if (nowMillis >= value) { return authenticationMcpFailure<Unit>("mcp.oauth_token_expired", "access token expired") }; case None => () }
    for (required in requiredScopes) {
        var granted = false
        for (scope in claims.scopes where scope == required) { granted = true; break }
        if (!granted) { return authorizationMcpFailure<Unit>("mcp.oauth_scope_required", "access token is missing a required scope") }
    }
    McpResult.Ok(())
}

func authenticationMcpFailure<T>(code: String, message: String): McpResult<T> {
    McpResult.Err(McpError(McpErrorKind.Authentication, code, message))
}
func authorizationMcpFailure<T>(code: String, message: String): McpResult<T> {
    McpResult.Err(McpError(McpErrorKind.Authorization, code, message))
}
func secureMcpMetadataUrl(value: String): Bool { secureMcpHttpUrl(value) }
func secureMcpRedirectUri(value: String): Bool { secureMcpHttpUrl(value) }
