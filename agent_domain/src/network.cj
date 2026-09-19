package agent_domain

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.deriving.*

@Derive[Equatable]
public enum NetworkPolicyMode {
    Denied | Mediated | HostNetwork
}

public let NETWORK_GATEWAY_MAX_RULES: Int64 = 128
public let NETWORK_GATEWAY_MAX_PRIVATE_ADDRESSES: Int64 = 16

public class NetworkEgressRule {
    public let host: String
    public let port: UInt16
    public let privateAddresses: Array<String>

    public init(
        host: String,
        port: UInt16,
        privateAddresses!: Array<String> = []
    ) {
        let normalized = normalizeNetworkHost(host)
        if (port == 0u16) {
            throw IllegalArgumentException("network egress port must be between 1 and 65535")
        }
        let addresses = normalizePrivateAddresses(privateAddresses)
        validateNetworkHostLiteral(normalized, addresses)
        this.host = normalized
        this.port = port
        this.privateAddresses = addresses
    }
}

public class NetworkPublishRule {
    public let hostPort: UInt16
    public let targetPort: UInt16

    public init(hostPort: UInt16, targetPort: UInt16) {
        if (hostPort == 0u16 || targetPort == 0u16) {
            throw IllegalArgumentException("network publish ports must be between 1 and 65535")
        }
        this.hostPort = hostPort
        this.targetPort = targetPort
    }
}

public class NetworkPolicy {
    public let mode: NetworkPolicyMode
    public let egress: Array<NetworkEgressRule>
    public let publish: Array<NetworkPublishRule>

    public init(
        mode: NetworkPolicyMode,
        egress!: Array<NetworkEgressRule> = [],
        publish!: Array<NetworkPublishRule> = []
    ) {
        if (mode == NetworkPolicyMode.Mediated) {
            if (egress.size > NETWORK_GATEWAY_MAX_RULES) {
                throw IllegalArgumentException(
                    "network policy exceeds the native gateway rule limit"
                )
            }
            for (rule in egress where
                 rule.privateAddresses.size > NETWORK_GATEWAY_MAX_PRIVATE_ADDRESSES) {
                throw IllegalArgumentException(
                    "network policy exceeds the native gateway private-address limit"
                )
            }
        }
        if (mode != NetworkPolicyMode.Mediated && (!egress.isEmpty() || !publish.isEmpty())) {
            throw IllegalArgumentException("only mediated network policy may contain rules")
        }
        this.mode = mode
        this.egress = normalizeEgressRules(egress)
        this.publish = normalizePublishRules(publish)
    }
}

public func networkPolicyModeName(mode: NetworkPolicyMode): String {
    match (mode) {
        case NetworkPolicyMode.Denied => "denied"
        case NetworkPolicyMode.Mediated => "proxy"
        case NetworkPolicyMode.HostNetwork => "host"
    }
}
public func networkPolicyModeIsDenied(mode: NetworkPolicyMode): Bool {
    match (mode) {
        case NetworkPolicyMode.Denied => true
        case NetworkPolicyMode.Mediated | NetworkPolicyMode.HostNetwork => false
    }
}

public func networkPolicyModeIsMediated(mode: NetworkPolicyMode): Bool {
    match (mode) {
        case NetworkPolicyMode.Mediated => true
        case NetworkPolicyMode.Denied | NetworkPolicyMode.HostNetwork => false
    }
}
public func networkPolicyModeIsHost(mode: NetworkPolicyMode): Bool {
    match (mode) {
        case NetworkPolicyMode.HostNetwork => true
        case NetworkPolicyMode.Denied | NetworkPolicyMode.Mediated => false
    }
}

public func networkPolicyMode(value: String): Result<NetworkPolicyMode> {
    match (value.trimAscii()) {
        case "denied" => Result.Ok(NetworkPolicyMode.Denied)
        case "proxy" => Result.Ok(NetworkPolicyMode.Mediated)
        case "host" => Result.Ok(NetworkPolicyMode.HostNetwork)
        case _ => networkPolicyError<NetworkPolicyMode>(
            "network.mode_invalid",
            "network mode must be denied, proxy, or host"
        )
    }
}

public func normalizeNetworkPolicy(
    mode: NetworkPolicyMode,
    egress!: Array<NetworkEgressRule> = [],
    publish!: Array<NetworkPublishRule> = []
): Result<NetworkPolicy> {
    try {
        Result.Ok(NetworkPolicy(mode, egress: egress, publish: publish))
    } catch (error: Exception) {
        networkPolicyError<NetworkPolicy>("network.policy_invalid", error.message)
    }
}

public func parseNetworkPolicy(value: AgentValue): Result<NetworkPolicy> {
    if (value.unifiedKind != ValueKind.Object) {
        return networkPolicyError<NetworkPolicy>(
            "network.policy_invalid",
            "network must be an object"
        )
    }
    let duplicate = duplicateNetworkField(value)
    if (duplicate != "") {
        return networkPolicyError<NetworkPolicy>(
            "network.field_duplicate",
            "duplicate network field: " + duplicate
        )
    }
    let modeValue = match (value.field("mode")) {
        case Some(item) => item
        case None => return networkPolicyError<NetworkPolicy>(
            "network.mode_required",
            "network.mode is required"
        )
    }
    if (modeValue.unifiedKind != ValueKind.Text) {
        return networkPolicyError<NetworkPolicy>(
            "network.mode_invalid",
            "network.mode must be a string"
        )
    }
    let mode = match (networkPolicyMode(modeValue.text)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    for (field in value.fields) {
        if (field.name != "mode" && field.name != "egress" && field.name != "publish") {
            return networkPolicyError<NetworkPolicy>(
                "network.field_unknown",
                "unknown network field: " + field.name
            )
        }
    }
    if (mode != NetworkPolicyMode.Mediated &&
        (value.field("egress").isSome() || value.field("publish").isSome())) {
        return networkPolicyError<NetworkPolicy>(
            "network.policy_rules_forbidden",
            "denied and host network policies cannot contain egress or publish"
        )
    }
    let egress = match (parseNetworkEgress(value)) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }
    let publish = match (parseNetworkPublish(value)) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }
    normalizeNetworkPolicy(mode, egress: egress, publish: publish)
}

public func networkPolicyCanonicalValue(policy: NetworkPolicy): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("mode", textValue(networkPolicyModeName(policy.mode))))
    if (!policy.egress.isEmpty()) {
        let values = ArrayList<AgentValue>()
        for (rule in policy.egress) {
            let addresses = ArrayList<AgentValue>()
            for (address in rule.privateAddresses) {
                addresses.add(textValue(address))
            }
            values.add(objectValue([
                ValueField("host", textValue(rule.host)),
                ValueField("port", integerValue(Int64(rule.port))),
                ValueField("private_addresses", listValue(addresses.toArray()))
            ]))
        }
        fields.add(ValueField("egress", listValue(values.toArray())))
    }
    if (!policy.publish.isEmpty()) {
        let values = ArrayList<AgentValue>()
        for (rule in policy.publish) {
            values.add(objectValue([
                ValueField("host_port", integerValue(Int64(rule.hostPort))),
                ValueField("target_port", integerValue(Int64(rule.targetPort)))
            ]))
        }
        fields.add(ValueField("publish", listValue(values.toArray())))
    }
    objectValue(fields.toArray())
}
public func networkPoliciesEqual(
    left: NetworkPolicy,
    right: NetworkPolicy
): Bool {
    if (left.mode != right.mode ||
        left.egress.size != right.egress.size ||
        left.publish.size != right.publish.size) {
        return false
    }
    for (index in 0..left.egress.size) {
        let a = left.egress[index]
        let b = right.egress[index]
        if (a.host != b.host || a.port != b.port ||
            a.privateAddresses != b.privateAddresses) {
            return false
        }
    }
    for (index in 0..left.publish.size) {
        let a = left.publish[index]
        let b = right.publish[index]
        if (a.hostPort != b.hostPort || a.targetPort != b.targetPort) {
            return false
        }
    }
    true
}

public func networkPolicyCapabilityResources(policy: NetworkPolicy): Array<String> {
    let values = ArrayList<String>()
    match (policy.mode) {
        case NetworkPolicyMode.Denied => ()
        case NetworkPolicyMode.HostNetwork => values.add("[\"host\"]")
        case NetworkPolicyMode.Mediated =>
            for (rule in policy.egress) {
                values.add(networkEgressResource(rule))
            }
            for (rule in policy.publish) {
                values.add(networkPublishResource(rule))
            }
    }
    values.toArray()
}

public func networkEgressResource(rule: NetworkEgressRule): String {
    let addresses = ArrayList<String>()
    for (address in rule.privateAddresses) {
        addresses.add("\"" + address + "\"")
    }
    "[\"egress\",\"" + rule.host + "\"," + Int64(rule.port).toString() + ",[" +
        joinNetworkStrings(addresses.toArray()) + "]]"
}

public func networkPublishResource(rule: NetworkPublishRule): String {
    "[\"publish\"," + Int64(rule.hostPort).toString() + "," +
        Int64(rule.targetPort).toString() + "]"
}

func parseNetworkEgress(value: AgentValue): Result<Array<NetworkEgressRule>> {
    let raw = match (value.field("egress")) {
        case Some(item) => item
        case None => return Result.Ok([])
    }
    if (raw.unifiedKind != ValueKind.List) {
        return networkPolicyError<Array<NetworkEgressRule>>(
            "network.egress_invalid",
            "network.egress must be a list"
        )
    }
    let result = ArrayList<NetworkEgressRule>()
    for (item in raw.items) {
        if (item.unifiedKind != ValueKind.Object) {
            return networkPolicyError<Array<NetworkEgressRule>>(
                "network.egress_invalid",
                "network egress rules must be objects"
            )
        }
        let duplicate = duplicateNetworkField(item)
        if (duplicate != "") {
            return networkPolicyError<Array<NetworkEgressRule>>(
                "network.egress_field_duplicate",
                "duplicate network egress field: " + duplicate
            )
        }
        let hostValue = match (item.field("host")) {
            case Some(field) => field
            case None => return networkPolicyError<Array<NetworkEgressRule>>(
                "network.egress_invalid", "network egress host is required"
            )
        }
        if (hostValue.unifiedKind != ValueKind.Text) {
            return networkPolicyError<Array<NetworkEgressRule>>(
                "network.egress_invalid", "network egress host must be a string"
            )
        }
        let port = match (networkPortValue(item, "port")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let privateAddresses = match (networkPrivateAddresses(item)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (field in item.fields) {
            if (field.name != "host" && field.name != "port" && field.name != "private_addresses") {
                return networkPolicyError<Array<NetworkEgressRule>>(
                    "network.egress_field_unknown",
                    "unknown network egress field: " + field.name
                )
            }
        }
        try {
            result.add(NetworkEgressRule(hostValue.text, port, privateAddresses: privateAddresses))
        } catch (error: Exception) {
            return networkPolicyError<Array<NetworkEgressRule>>("network.egress_invalid", error.message)
        }
    }
    Result.Ok(result.toArray())
}

func parseNetworkPublish(value: AgentValue): Result<Array<NetworkPublishRule>> {
    let raw = match (value.field("publish")) {
        case Some(item) => item
        case None => return Result.Ok([])
    }
    if (raw.unifiedKind != ValueKind.List) {
        return networkPolicyError<Array<NetworkPublishRule>>(
            "network.publish_invalid", "network.publish must be a list"
        )
    }
    let result = ArrayList<NetworkPublishRule>()
    for (item in raw.items) {
        if (item.unifiedKind != ValueKind.Object) {
            return networkPolicyError<Array<NetworkPublishRule>>(
                "network.publish_invalid", "network publish rules must be objects"
            )
        }
        let duplicate = duplicateNetworkField(item)
        if (duplicate != "") {
            return networkPolicyError<Array<NetworkPublishRule>>(
                "network.publish_field_duplicate",
                "duplicate network publish field: " + duplicate
            )
        }
        let hostPort = match (networkPortValue(item, "host_port")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let targetPort = match (networkPortValue(item, "target_port")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (field in item.fields) {
            if (field.name != "host_port" && field.name != "target_port") {
                return networkPolicyError<Array<NetworkPublishRule>>(
                    "network.publish_field_unknown",
                    "unknown network publish field: " + field.name
                )
            }
        }
        try {
            result.add(NetworkPublishRule(hostPort, targetPort))
        } catch (error: Exception) {
            return networkPolicyError<Array<NetworkPublishRule>>("network.publish_invalid", error.message)
        }
    }
    Result.Ok(result.toArray())
}

func networkPortValue(value: AgentValue, name: String): Result<UInt16> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return networkPolicyError<UInt16>(
            "network.port_invalid", name + " is required"
        )
    }
    if (field.unifiedKind != ValueKind.Number) {
        return networkPolicyError<UInt16>(
            "network.port_invalid", name + " must be an integer"
        )
    }
    try {
        let parsed = Int64.parse(field.text)
        if (parsed < 1 || parsed > 65535) {
            return networkPolicyError<UInt16>(
                "network.port_invalid", name + " must be between 1 and 65535"
            )
        }
        Result.Ok(UInt16(parsed))
    } catch (_: Exception) {
        networkPolicyError<UInt16>("network.port_invalid", name + " must be an integer")
    }
}

func networkPrivateAddresses(value: AgentValue): Result<Array<String>> {
    let field = match (value.field("private_addresses")) {
        case Some(item) => item
        case None => return Result.Ok([])
    }
    if (field.unifiedKind != ValueKind.List) {
        return networkPolicyError<Array<String>>(
            "network.private_addresses_invalid", "private_addresses must be a list"
        )
    }
    let values = ArrayList<String>()
    for (item in field.items) {
        if (item.unifiedKind != ValueKind.Text) {
            return networkPolicyError<Array<String>>(
                "network.private_addresses_invalid", "private address must be a string"
            )
        }
        try {
            let address = normalizeIpLiteral(item.text)
            if (!isAllowedPrivateAddress(address)) {
                return networkPolicyError<Array<String>>(
                    "network.private_address_invalid",
                    "private address is not an allowed private exception: " + address
                )
            }
            addSortedUnique(values, address)
        } catch (error: Exception) {
            return networkPolicyError<Array<String>>(
                "network.private_address_invalid", error.message
            )
        }
    }
    Result.Ok(values.toArray())
}

func normalizeNetworkHost(value: String): String {
    var host = value.trimAscii()
    if (host == "" || host != value || host.contains("\u{0000}") || host.contains("%") ||
        host.contains("@") || host.contains("/") || host.contains("?") || host.contains("#") ||
        host.contains("*") || host.contains("[") || host.contains("]")) {
        throw IllegalArgumentException("network host is not a strict authority")
    }
    if (host.endsWith(".")) {
        host = host[..host.size - 1]
        if (host.endsWith(".")) {
            throw IllegalArgumentException("network host has repeated trailing dots")
        }
    }
    if (host == "") { throw IllegalArgumentException("network host must not be empty") }
    let bytes = unsafe { host.rawData() }
    for (byte in bytes) {
        if (byte < 0x21u8 || byte > 0x7eu8) {
            throw IllegalArgumentException("network host must be ASCII without control characters")
        }
    }
    if (host.contains(":")) {
        return normalizeIpLiteral(host)
    }
    if (isAsciiDecimalIp(host)) {
        return normalizeIpv4(host)
    }
    normalizeDnsHost(host)
}

func normalizeIpLiteral(value: String): String {
    let host = value.trimAscii()
    if (host == "" || host != value || host.contains("%") || host.contains("[") || host.contains("]")) {
        throw IllegalArgumentException("IP literal is invalid")
    }
    if (isAsciiDecimalIp(host)) { return normalizeIpv4(host) }
    if (host.contains(":")) {
        let lower = host.toAsciiLower()
        if (lower.startsWith("::ffff:")) {
            let mapped = lower[7..]
            if (mapped.contains(".")) {
                return "::ffff:" + normalizeIpv4(mapped)
            }
        }
        if (!validIpv6(lower)) {
            throw IllegalArgumentException("IPv6 literal is invalid")
        }
        return lower
    }
    throw IllegalArgumentException("IP literal is invalid")
}

func normalizeIpv4(value: String): String {
    let parts = value.split(".")
    if (parts.size != 4) { throw IllegalArgumentException("IPv4 literal is invalid") }
    let normalized = ArrayList<String>()
    for (part in parts) {
        if (part == "" || part.size > 3 || (part.size > 1 && part.startsWith("0"))) {
            throw IllegalArgumentException("IPv4 literal is not canonical")
        }
        var number: Int64 = 0
        for (byte in unsafe { part.rawData() }) {
            if (byte < b'0' || byte > b'9') {
                throw IllegalArgumentException("IPv4 literal is invalid")
            }
            number = number * 10 + Int64(byte - b'0')
        }
        if (number > 255) { throw IllegalArgumentException("IPv4 literal is invalid") }
        normalized.add(number.toString())
    }
    joinNetworkStrings(normalized.toArray(), separator: ".")
}

func normalizeDnsHost(value: String): String {
    let lower = value.toAsciiLower()
    let labels = lower.split(".")
    if (labels.isEmpty() || lower.size > 253) {
        throw IllegalArgumentException("DNS host is invalid")
    }
    for (label in labels) {
        if (label == "" || label.size > 63 || label.startsWith("-") || label.endsWith("-")) {
            throw IllegalArgumentException("DNS label is invalid")
        }
        for (byte in unsafe { label.rawData() }) {
            let valid = (byte >= b'a' && byte <= b'z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'-'
            if (!valid) { throw IllegalArgumentException("DNS host must be ASCII") }
        }
    }
    lower
}

func isAsciiDecimalIp(value: String): Bool {
    if (!value.contains(".")) { return false }
    for (byte in unsafe { value.rawData() }) {
        if ((byte < b'0' || byte > b'9') && byte != b'.') { return false }
    }
    true
}

func validIpv6(value: String): Bool {
    let double = value.indexOf("::")
    if (double.isNone() && (value.startsWith(":") || value.endsWith(":"))) {
        return false
    }
    if (double.isSome()) {
        let index = double.getOrThrow()
        let before = value[..index]
        let after = value[index + 2..]
        if (before.endsWith(":") || after.startsWith(":") ||
            after.contains("::")) {
            return false
        }
    }
    let pieces = if (double.isSome()) {
        value.replace("::", ":").split(":")
    } else {
        value.split(":")
    }
    var count = 0
    var hasIpv4 = false
    for (piece in pieces) {
        if (piece == "") { continue }
        if (piece.contains(".")) {
            if (hasIpv4 || !isAsciiDecimalIp(piece)) { return false }
            try { _ = normalizeIpv4(piece) } catch (_: Exception) { return false }
            hasIpv4 = true
            count += 2
        } else {
            if (hasIpv4 || piece.size < 1 || piece.size > 4) { return false }
            for (byte in unsafe { piece.rawData() }) {
                let valid = (byte >= b'0' && byte <= b'9') ||
                    (byte >= b'a' && byte <= b'f') || (byte >= b'A' && byte <= b'F')
                if (!valid) { return false }
            }
            count += 1
        }
    }
    if (double.isSome()) { count < 8 } else { count == 8 }
}

func parseIpv6Hextets(value: String): ?Array<Int64> {
    let double = value.indexOf("::")
    let before = if (double.isSome()) {
        value[..double.getOrThrow()]
    } else {
        value
    }
    let after = if (double.isSome()) {
        value[double.getOrThrow() + 2..]
    } else {
        ""
    }
    let beforeFields: Array<String> = if (before == "") { [] } else { before.split(":") }
    let afterFields: Array<String> = if (after == "") { [] } else { after.split(":") }
    if (!double.isSome() && beforeFields.size != 8) { return None }
    if (double.isSome() && beforeFields.size + afterFields.size >= 8) { return None }
    let result = ArrayList<Int64>()
    for (field in beforeFields) {
        match (parseIpv6Hextet(field)) {
            case Some(parsed) => result.add(parsed)
            case None => return None
        }
    }
    if (double.isSome()) {
        for (_ in 0..(8 - beforeFields.size - afterFields.size)) {
            result.add(0)
        }
    }
    for (field in afterFields) {
        match (parseIpv6Hextet(field)) {
            case Some(parsed) => result.add(parsed)
            case None => return None
        }
    }
    if (result.size != 8) { return None }
    Some(result.toArray())
}

func isForbiddenIpv6Metadata(value: String): Bool {
    let parts = match (parseIpv6Hextets(value.toAsciiLower())) {
        case Some(parsed) => parsed
        case None => return false
    }
    parts[0] == 0xfd00 && parts[1] == 0x0ec2 &&
        parts[2] == 0 && parts[3] == 0 && parts[4] == 0 &&
        parts[5] == 0 && parts[6] == 0 && parts[7] == 0x0254
}

func isAllowedPrivateAddress(value: String): Bool {
    if (value == "100.100.100.200" || value == "168.63.129.16" ||
        isForbiddenIpv6Metadata(value)) {
        return false
    }
    if (value.contains(":")) {
        let lower = value.toAsciiLower()
        if (lower.startsWith("::ffff:") && lower[7..].contains(".")) {
            return isAllowedPrivateAddress(lower[7..])
        }
        return lower == "::1" || lower.startsWith("fc") || lower.startsWith("fd")
    }
    let octets = value.split(".")
    if (octets.size != 4) { return false }
    let a = Int64.parse(octets[0])
    let b = Int64.parse(octets[1])
    (a == 10) || (a == 127) || (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) || (a == 100 && b >= 64 && b <= 127)
}

func validateNetworkHostLiteral(
    host: String,
    privateAddresses: Array<String>
): Unit {
    if (host == "100.100.100.200" || host == "168.63.129.16" ||
        isForbiddenIpv6Metadata(host)) {
        throw IllegalArgumentException("network host is a forbidden metadata address")
    }
    if (host.contains(":")) {
        let lower = host.toAsciiLower()
        if (lower.startsWith("::ffff:") && lower[7..].contains(".")) {
            validateNetworkHostLiteral(lower[7..], privateAddresses)
            return
        }
        if (isAllowedPrivateAddress(lower)) {
            if (!networkPrivateAddressMatches(lower, privateAddresses)) {
                throw IllegalArgumentException(
                    "private network host requires an explicit private_addresses exception"
                )
            }
            return
        }
        if (!isPublicIpv6Literal(lower)) {
            throw IllegalArgumentException("network IPv6 host is not an allowed public address")
        }
        return
    }
    if (isAsciiDecimalIp(host) && !isPublicIpv4Literal(host) &&
        !networkPrivateAddressMatches(host, privateAddresses)) {
        throw IllegalArgumentException(
            "private network host requires an explicit private_addresses exception"
        )
    }
}

func networkPrivateAddressMatches(
    host: String,
    privateAddresses: Array<String>
): Bool {
    for (address in privateAddresses) {
        if (address == host) { return true }
        if (host.startsWith("::ffff:") && host[7..] == address) { return true }
        if (address.startsWith("::ffff:") && address[7..] == host) { return true }
    }
    false
}

func isPublicIpv4Literal(value: String): Bool {
    let octets = value.split(".")
    if (octets.size != 4) { return false }
    let a = Int64.parse(octets[0])
    let b = Int64.parse(octets[1])
    let c = Int64.parse(octets[2])
    if (a == 0 || a == 10 || a == 127 || a >= 224) { return false }
    if (a == 100 && b >= 64 && b <= 127) { return false }
    if (a == 169 && b == 254) { return false }
    if (a == 172 && b >= 16 && b <= 31) { return false }
    if (a == 192 && (
        b == 168 ||
        (b == 0 && c == 0) ||
        (b == 0 && c == 2) ||
        (b == 88 && c == 99)
    )) { return false }
    if (a == 198 && (
        (b == 18 || b == 19) ||
        (b == 51 && c == 100)
    )) { return false }
    if (a == 203 && b == 0 && c == 113) { return false }
    true
}

func parseIpv6Hextet(value: String): ?Int64 {
    if (value == "" || value.size > 4) { return None }
    var result: Int64 = 0
    for (byte in unsafe { value.rawData() }) {
        let digit: Int64 = if (byte >= b'0' && byte <= b'9') {
            Int64(byte - b'0')
        } else if (byte >= b'a' && byte <= b'f') {
            Int64(byte - b'a') + 10
        } else if (byte >= b'A' && byte <= b'F') {
            Int64(byte - b'A') + 10
        } else {
            return None
        }
        result = result * 16 + digit
    }
    Some(result)
}

func ipv6PrefixHextets(value: String): ?Array<Int64> {
    let double = value.indexOf("::")
    let before = match (double) {
        case Some(index) => value[..index]
        case None => value
    }
    let fields = before.split(":")
    var first: Int64 = 0
    var second: Int64 = 0
    if (fields.size > 0 && fields[0] != "") {
        first = match (parseIpv6Hextet(fields[0])) {
            case Some(parsed) => parsed
            case None => return None
        }
    }
    if (fields.size > 1 && fields[1] != "") {
        second = match (parseIpv6Hextet(fields[1])) {
            case Some(parsed) => parsed
            case None => return None
        }
    }
    Some([first, second])
}

func isPublicIpv6Literal(value: String): Bool {
    let prefix = match (ipv6PrefixHextets(value)) {
        case Some(value) => value
        case None => return false
    }
    let first = prefix[0]
    let second = prefix[1]
    if (first < 8192 || first > 16383) { return false }
    // 2001::/23 is 2001:0000:: through 2001:01ff::.
    if (first == 8193 && (second <= 511 || second == 3512)) { return false }
    if (first == 8194) { return false }
    // 3fff::/20 covers the low /12 of the second hextet.
    if (first == 16383 && second <= 4095) { return false }
    true
}
func normalizePrivateAddresses(values: Array<String>): Array<String> {
    let result = ArrayList<String>()
    for (value in values) {
        let normalized = normalizeIpLiteral(value)
        if (!isAllowedPrivateAddress(normalized)) {
            throw IllegalArgumentException("private address is not an allowed private exception")
        }
        addSortedUnique(result, normalized)
    }
    result.toArray()
}

func normalizeEgressRules(values: Array<NetworkEgressRule>): Array<NetworkEgressRule> {
    let result = ArrayList<NetworkEgressRule>()
    for (value in values) {
        let normalized = NetworkEgressRule(
            value.host,
            value.port,
            privateAddresses: value.privateAddresses
        )
        var duplicate = false
        for (existing in result where existing.host == normalized.host &&
            existing.port == normalized.port &&
            joinNetworkStrings(existing.privateAddresses) == joinNetworkStrings(normalized.privateAddresses)) {
            duplicate = true
        }
        if (!duplicate) { result.add(normalized) }
    }
    sortEgressRules(result)
    result.toArray()
}

func normalizePublishRules(values: Array<NetworkPublishRule>): Array<NetworkPublishRule> {
    let result = ArrayList<NetworkPublishRule>()
    for (value in values) {
        var duplicate = false
        for (existing in result where existing.hostPort == value.hostPort && existing.targetPort == value.targetPort) {
            duplicate = true
        }
        if (!duplicate) { result.add(NetworkPublishRule(value.hostPort, value.targetPort)) }
    }
    sortPublishRules(result)
    result.toArray()
}

func sortEgressRules(values: ArrayList<NetworkEgressRule>): Unit {
    var sorted = ArrayList<NetworkEgressRule>()
    for (value in values) {
        let key = networkEgressSortKey(value)
        var inserted = false
        let next = ArrayList<NetworkEgressRule>()
        for (existing in sorted) {
            if (!inserted && key < networkEgressSortKey(existing)) {
                next.add(value)
                inserted = true
            }
            next.add(existing)
        }
        if (!inserted) { next.add(value) }
        sorted = next
    }
    values.clear()
    values.add(all: sorted.toArray())
}

func sortPublishRules(values: ArrayList<NetworkPublishRule>): Unit {
    var sorted = ArrayList<NetworkPublishRule>()
    for (value in values) {
        let key = networkPublishSortKey(value)
        var inserted = false
        let next = ArrayList<NetworkPublishRule>()
        for (existing in sorted) {
            if (!inserted && key < networkPublishSortKey(existing)) {
                next.add(value)
                inserted = true
            }
            next.add(existing)
        }
        if (!inserted) { next.add(value) }
        sorted = next
    }
    values.clear()
    values.add(all: sorted.toArray())
}
public func requireNetworkPolicy(value: AgentValue): NetworkPolicy {
    match (parseNetworkPolicy(value)) {
        case Result.Ok(policy) => policy
        case Result.Err(error) => throw IllegalArgumentException(error.message)
    }
}
public func networkAddressDeniedError(
    host: String,
    port!: UInt16 = 0u16,
    reason!: String = "network destination is not authorized"
): AgentError {
    let fields = if (port == 0u16) {
        [ErrorField("host", host)]
    } else {
        [
            ErrorField("host", host),
            ErrorField("port", Int64(port).toString())
        ]
    }
    AgentError(
        AgentErrorKind.PermissionDenied,
        "network.address_denied",
        reason,
        retryable: false,
        fallbackAllowed: false,
        fields: fields
    )
}
public func networkGatewayUnavailableError(): AgentError {
    AgentError(
        AgentErrorKind.Transport,
        "network.gateway_unavailable",
        "mediated network access requires an available network gateway",
        retryable: false,
        fallbackAllowed: false
    )
}


func networkEgressSortKey(value: NetworkEgressRule): String {
    value.host + "\u{0000}" + Int64(value.port).toString() + "\u{0000}" +
        joinNetworkStrings(value.privateAddresses)
}

func networkPublishSortKey(value: NetworkPublishRule): String {
    Int64(value.hostPort).toString() + "\u{0000}" + Int64(value.targetPort).toString()
}

func duplicateNetworkField(value: AgentValue): String {
    let seen = ArrayList<String>()
    for (field in value.fields) {
        for (name in seen where name == field.name) {
            return field.name
        }
        seen.add(field.name)
    }
    ""
}

func addSortedUnique(values: ArrayList<String>, value: String): Unit {
    for (existing in values where existing == value) { return }
    var inserted = false
    let next = ArrayList<String>()
    for (existing in values) {
        if (!inserted && value < existing) {
            next.add(value)
            inserted = true
        }
        next.add(existing)
    }
    if (!inserted) { next.add(value) }
    values.clear()
    values.add(all: next.toArray())
}

func joinNetworkStrings(values: Array<String>, separator!: String = ","): String {
    var result = ""
    for (value in values) {
        if (result != "") { result += separator }
        result += value
    }
    result
}

func networkPolicyError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
