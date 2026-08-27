package mcp4cj

import std.sync.*

public class McpPkceAuthorizationGrant {
    public let code: String
    public let redirectUri: String
    public let codeVerifier: String
    public let returnedIssuer: String
    public init(code: String, redirectUri: String, codeVerifier: String, returnedIssuer: String) {
        if (code.trimAscii() == "" || codeVerifier.size < 43 || codeVerifier.size > 128 || !secureMcpRedirectUri(redirectUri)) {
            throw IllegalArgumentException("invalid MCP PKCE authorization grant")
        }
        this.code = code; this.redirectUri = redirectUri; this.codeVerifier = codeVerifier; this.returnedIssuer = returnedIssuer
    }
}

public interface McpOAuthAuthorizationInteraction {
    // Implementations create a high-entropy verifier, derive an S256 challenge,
    // bind state, open the authorization endpoint, and validate the callback.
    func authorize(
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata,
        resource: String,
        scopes: Array<String>
    ): McpResult<McpPkceAuthorizationGrant>
}

public interface McpOAuthTokenStore {
    func load(resource: String, issuer: String, clientId: String): McpResult<?McpOAuthTokenSet>
    func save(resource: String, issuer: String, clientId: String, tokens: McpOAuthTokenSet): McpResult<Unit>
    func clear(resource: String, issuer: String, clientId: String): McpResult<Unit>
}

public class MemoryMcpOAuthTokenStore <: McpOAuthTokenStore {
    private let lock = Mutex()
    private var resource = ""
    private var issuer = ""
    private var clientId = ""
    private var tokens: ?McpOAuthTokenSet = None
    public init() {}
    public func load(resource: String, issuer: String, clientId: String): McpResult<?McpOAuthTokenSet> {
        lock.lock(); try {
            if (this.resource == resource && this.issuer == issuer && this.clientId == clientId) { McpResult.Ok(tokens) }
            else { McpResult.Ok(None) }
        } finally { lock.unlock() }
    }
    public func save(resource: String, issuer: String, clientId: String, tokens: McpOAuthTokenSet): McpResult<Unit> {
        lock.lock(); try {
            this.resource = resource; this.issuer = issuer; this.clientId = clientId; this.tokens = Some(tokens)
            McpResult.Ok(())
        } finally { lock.unlock() }
    }
    public func clear(resource: String, issuer: String, clientId: String): McpResult<Unit> {
        lock.lock(); try {
            if (this.resource == resource && this.issuer == issuer && this.clientId == clientId) { tokens = None }
            McpResult.Ok(())
        } finally { lock.unlock() }
    }
}

public class McpOAuthClient {
    private let metadataFetcher: McpOAuthMetadataFetcher
    private let registration: McpOAuthClientRegistration
    private let interaction: McpOAuthAuthorizationInteraction
    private let exchange: McpOAuthTokenExchange
    private let store: McpOAuthTokenStore

    public init(
        metadataFetcher: McpOAuthMetadataFetcher,
        registration: McpOAuthClientRegistration,
        interaction: McpOAuthAuthorizationInteraction,
        exchange: McpOAuthTokenExchange,
        store!: McpOAuthTokenStore = MemoryMcpOAuthTokenStore()
    ) {
        this.metadataFetcher = metadataFetcher; this.registration = registration
        this.interaction = interaction; this.exchange = exchange; this.store = store
    }

    public func accessToken(resource: String, scopes: Array<String>, nowMillis: Int64): McpResult<McpOAuthTokenSet> {
        let prepared = match (prepare(resource)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        let metadata = prepared[0]
        let client = prepared[1]
        let current = match (store.load(resource, metadata.issuer, client.clientId)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        match (current) {
            case Some(tokens) =>
                if (!tokens.expired(nowMillis) && tokens.covers(scopes)) { return McpResult.Ok(tokens) }
                if (tokens.refreshToken != "") {
                    match (exchange.refresh(metadata, client, tokens.refreshToken, resource, scopes)) {
                        case McpResult.Ok(refreshed) =>
                            if (!refreshed.covers(scopes)) { return authorizationMcpFailure<McpOAuthTokenSet>("mcp.oauth_scope_required", "refreshed access token did not grant requested scopes") }
                            match (store.save(resource, metadata.issuer, client.clientId, refreshed)) {
                                case McpResult.Ok(_) => return McpResult.Ok(refreshed)
                                case McpResult.Err(error) => return McpResult.Err(error)
                            }
                        case McpResult.Err(_) => ()
                    }
                }
            case None => ()
        }
        authorize(resource, scopes, metadata, client)
    }

    public func clear(resource: String): McpResult<Unit> {
        let prepared = match (prepare(resource)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        store.clear(resource, prepared[0].issuer, prepared[1].clientId)
    }

    private func prepare(resource: String): McpResult<(McpAuthorizationServerMetadata, McpOAuthClientMetadata)> {
        let protected = match (metadataFetcher.protectedResource(resource)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (protected.resource != resource || protected.authorizationServers.isEmpty()) {
            return authenticationMcpFailure<(McpAuthorizationServerMetadata, McpOAuthClientMetadata)>("mcp.oauth_resource_metadata_invalid", "protected resource metadata does not match requested resource")
        }
        let metadata = match (metadataFetcher.authorizationServer(protected.authorizationServers[0])) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (metadata.issuer != protected.authorizationServers[0]) {
            return authenticationMcpFailure<(McpAuthorizationServerMetadata, McpOAuthClientMetadata)>("mcp.oauth_issuer_mismatch", "authorization server metadata issuer mismatch")
        }
        if (!metadata.supportsS256()) {
            return authenticationMcpFailure<(McpAuthorizationServerMetadata, McpOAuthClientMetadata)>("mcp.oauth_pkce_s256_required", "authorization server does not advertise PKCE S256")
        }
        let client = match (registration.clientMetadataDocument(metadata.issuer)) {
            case McpResult.Ok(Some(value)) => value
            case McpResult.Ok(None) => match (registration.preRegistered(metadata.issuer)) {
                case McpResult.Ok(Some(value)) => value
                case McpResult.Ok(None) => match (registration.dynamicRegister(metadata)) {
                    case McpResult.Ok(value) => value
                    case McpResult.Err(error) => return McpResult.Err(error)
                }
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        McpResult.Ok((metadata, client))
    }

    private func authorize(
        resource: String,
        scopes: Array<String>,
        metadata: McpAuthorizationServerMetadata,
        client: McpOAuthClientMetadata
    ): McpResult<McpOAuthTokenSet> {
        let grant = match (interaction.authorize(metadata, client, resource, scopes)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        match (validateMcpAuthorizationResponseIssuer(
            grant.returnedIssuer, metadata.issuer, metadata.authorizationResponseIssParameterSupported
        )) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        var redirectAllowed = false
        for (uri in client.redirectUris where uri == grant.redirectUri) { redirectAllowed = true; break }
        if (!redirectAllowed) {
            return authenticationMcpFailure<McpOAuthTokenSet>("mcp.oauth_redirect_mismatch", "authorization response used an unregistered redirect URI")
        }
        let tokens = match (exchange.exchangeAuthorizationCode(
            metadata, client, grant.code, grant.redirectUri, grant.codeVerifier, resource
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (!tokens.covers(scopes)) {
            return authorizationMcpFailure<McpOAuthTokenSet>("mcp.oauth_scope_required", "authorization server did not grant requested scopes")
        }
        match (store.save(resource, metadata.issuer, client.clientId, tokens)) {
            case McpResult.Ok(_) => McpResult.Ok(tokens)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }
}

public func validateMcpAuthorizationResponseIssuer(
    returnedIssuer: String,
    expectedIssuer: String,
    issuerParameterSupported: Bool
): McpResult<Unit> {
    if (expectedIssuer == "") { return McpResult.Ok(()) }
    if (returnedIssuer == "") {
        if (issuerParameterSupported) {
            return authenticationMcpFailure<Unit>(
                "mcp.oauth_issuer_missing", "authorization response omitted its advertised issuer"
            )
        }
        return McpResult.Ok(())
    }
    if (returnedIssuer != expectedIssuer) {
        return authenticationMcpFailure<Unit>(
            "mcp.oauth_issuer_mismatch", "authorization response issuer mismatch"
        )
    }
    McpResult.Ok(())
}

public class McpResourceServerAuthorizer {
    private let verifier: McpAccessTokenVerifier
    private let resource: String
    private let issuer: String
    public init(verifier: McpAccessTokenVerifier, resource: String, issuer: String) {
        if (!secureMcpMetadataUrl(resource) || !secureMcpMetadataUrl(issuer)) { throw IllegalArgumentException("MCP resource server requires secure resource and issuer URLs") }
        this.verifier = verifier; this.resource = resource; this.issuer = issuer
    }
    public func authorize(accessToken: String, scopes: Array<String>, nowMillis: Int64): McpResult<McpTokenClaims> {
        let claims = match (verifier.verify(accessToken, resource, nowMillis)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        match (validateMcpTokenClaims(claims, issuer, resource, scopes, nowMillis)) {
            case McpResult.Ok(_) => McpResult.Ok(claims)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }
}
