package web_search_plugin

import std.collection.*
import yjson.*
import yjson_support.*

class SearchField {
    let name: String
    let value: String
    init(name: String, value: String) { this.name = name; this.value = value }
}

// A provider's logical credential location, not a host grant or wire format.
// The protocol adapter must resolve it using the eventual generic broker API.
enum SearchCredentialPlacement { Header(String) | JsonField(String) }

class SearchCredentialRequirement {
    let provider: String
    let placement: SearchCredentialPlacement
    init(provider: String, placement: SearchCredentialPlacement) { this.provider = provider; this.placement = placement }
}

class SearchRequest {
    let provider: String
    let method: String
    let url: String
    let query: Array<SearchField>
    let headers: Array<SearchField>
    let jsonBody: ?JsonNode
    let credential: ?SearchCredentialRequirement
    init(provider: String, method: String, url: String, query: Array<SearchField>, headers: Array<SearchField>,
        jsonBody: ?JsonNode, credential: ?SearchCredentialRequirement) {
        this.provider = provider; this.method = method; this.url = url
        this.query = query; this.headers = headers; this.jsonBody = jsonBody; this.credential = credential
    }
}

enum SearchPlan { Request(SearchRequest) | Immediate(JsonNode) }

func prepareSearch(input: SearchInput, available: SearchAvailability): SearchPlan {
    let provider = selectSearchProvider(input, available)
    if (provider == "none") {
        return SearchPlan.Immediate(searchFailureResult(provider, "No web search provider configured."))
    }
    if ((provider == "brave" && !available.brave) || (provider == "tavily" && !available.tavily) ||
        (provider == "searxng" && available.searxEndpoint == "")) {
        return SearchPlan.Immediate(searchFailureResult(provider, searchProviderLabel(provider) + " is not configured."))
    }
    SearchPlan.Request(buildSearchRequest(input, provider, available.searxEndpoint))
}

func buildSearchRequest(input: SearchInput, provider: String, searxEndpoint: String): SearchRequest {
    match (provider) {
        case "brave" =>
            let query = ArrayList<SearchField>([SearchField("q", input.query), SearchField("count", input.limit.toString())])
            if (input.recency != "") { query.add(SearchField("freshness", searchBraveRecency(input.recency))) }
            SearchRequest(provider, "GET", "https://api.search.brave.com/res/v1/web/search", query.toArray(),
                [SearchField("Accept", "application/json")], None,
                Some(SearchCredentialRequirement(provider, SearchCredentialPlacement.Header("X-Subscription-Token"))))
        case "tavily" =>
            let body = jsonObject([
                JsonObjectEntry("query", jsonString(input.query)), JsonObjectEntry("max_results", jsonNumber(input.limit.toString())),
                JsonObjectEntry("include_answer", jsonBool(true)), JsonObjectEntry("search_depth", jsonString("basic"))
            ])
            if (input.recency != "") { body.put("time_range", jsonString(input.recency)) }
            match (input.maxTokens) { case Some(value) => body.put("max_tokens", jsonNumber(value)); case None => () }
            SearchRequest(provider, "POST", "https://api.tavily.com/search", [],
                [SearchField("Content-Type", "application/json")], Some(body),
                Some(SearchCredentialRequirement(provider, SearchCredentialPlacement.JsonField("api_key"))))
        case "searxng" =>
            SearchRequest(provider, "GET", searxEndpoint.removeSuffix("/") + "/search", [
                SearchField("q", input.query), SearchField("format", "json"), SearchField("limit", input.limit.toString()),
                SearchField("time_range", input.recency)
            ], [], None, None)
        case _ => throw SearchFailure("tool.web_search_invalid_argument", "unsupported web search provider: " + provider)
    }
}

func searchBraveRecency(value: String): String {
    match (value) { case "day" => "pd"; case "week" => "pw"; case "month" => "pm"; case "year" => "py"; case _ => "" }
}
