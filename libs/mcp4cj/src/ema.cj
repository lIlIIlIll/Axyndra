package mcp4cj

import json4cj.*

public let MCP_EMA_EXTENSION = "io.modelcontextprotocol/enterprise-managed-authorization"

public class McpEnterpriseAuthorizationContext {
    public let resource: String
    public let organization: String
    public let subject: String
    public let requestedScopes: Array<String>
    public let attributes: JsonValue
    public init(
        resource: String,
        organization: String,
        subject: String,
        requestedScopes!: Array<String> = [],
        attributes!: JsonValue = JsonValue.objectValue([])
    ) {
        if (resource.trimAscii() == "" || organization.trimAscii() == "" || subject.trimAscii() == "") {
            throw IllegalArgumentException("MCP enterprise authorization context requires resource, organization, and subject")
        }
        requireObject(attributes, "MCP enterprise authorization attributes")
        this.resource = resource; this.organization = organization; this.subject = subject
        this.requestedScopes = requestedScopes; this.attributes = attributes
    }
}

public interface McpEnterpriseAuthorizationPolicy {
    func authorize(context: McpEnterpriseAuthorizationContext): McpResult<Unit>
}

public interface McpEnterpriseCredentialProvider {
    func acquire(context: McpEnterpriseAuthorizationContext): McpResult<McpOAuthTokenSet>
    func refresh(context: McpEnterpriseAuthorizationContext, current: McpOAuthTokenSet): McpResult<McpOAuthTokenSet>
}
