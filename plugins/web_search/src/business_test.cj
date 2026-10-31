package web_search_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func inputFixture(json: String): SearchInput { decodeSearchInput(parseUnifiedJson(json)) }
func requestFixture(json: String, available!: SearchAvailability = SearchAvailability(brave: true, tavily: true,
    searxEndpoint: "https://search.example.test/")): SearchRequest {
    match (prepareSearch(inputFixture(json), available)) {
        case SearchPlan.Request(value) => value
        case _ => throw IllegalStateException("fixture expected a request")
    }
}
func immediateFixture(json: String, available!: SearchAvailability = SearchAvailability()): JsonNode {
    match (prepareSearch(inputFixture(json), available)) {
        case SearchPlan.Immediate(value) => value
        case _ => throw IllegalStateException("fixture expected no request")
    }
}
func fieldFixture(fields: Array<SearchField>, name: String): String {
    for (field in fields where field.name == name) { return field.value }
    throw IllegalStateException("missing fixture field: " + name)
}
func inputRejected(json: String): Bool {
    try { let _ = inputFixture(json); false } catch (error: SearchFailure) { error.code == "tool.web_search_invalid_argument" }
}
func commandRejected(arguments: Array<String>): Bool {
    try { let _ = parseSearchCommand(arguments); false } catch (error: SearchFailure) { error.code == "web_search.command_argument" }
}

@Test
class SearchInputTests {
    @TestCase
    func schemaPreservesSevenFieldsAndOnlyQueryIsRequired() {
        let schema = searchSchema()
        @Expect(schema.field("properties").getOrThrow().fields.size, 7)
        @Expect(schema.field("required").getOrThrow().items.size, 1)
        @Expect(schema.field("required").getOrThrow().items[0].text, "query")
        @Expect(schema.field("additionalProperties").getOrThrow().asBool(), false)
    }
    @TestCase
    func trimsQueryAndRetainsDefaults() {
        let input = inputFixture("{\"query\":\"  Cangjie 文档\\n\"}")
        @Expect(input.query, "Cangjie 文档")
        @Expect(input.provider, "auto")
        @Expect(input.limit, 10)
        @Expect(input.recency, "")
    }
    @TestCase
    func rejectsSchemaTypeUnknownFieldsAndUnsafeQuery() {
        for (value in ["[]", "{}", "{\"query\":0}", "{\"query\":\"  \"}", "{\"query\":\"a\\u0000b\"}",
            "{\"query\":\"q\",\"extra\":1}", "{\"query\":\"q\",\"limit\":\"3\"}",
            "{\"query\":\"q\",\"provider\":\"Brave\"}", "{\"query\":\"q\",\"recency\":\"forever\"}"]) {
            @Expect(inputRejected(value), true)
        }
    }
    @TestCase
    func resultCountOverrideAndClampsMatchLegacy() {
        @Expect(inputFixture("{\"query\":\"q\",\"limit\":4,\"num_search_results\":7}").limit, 7)
        @Expect(inputFixture("{\"query\":\"q\",\"limit\":0}").limit, 1)
        @Expect(inputFixture("{\"query\":\"q\",\"num_search_results\":1000}").limit, 20)
        @Expect(inputFixture("{\"query\":\"q\",\"limit\":5,\"num_search_results\":1.5}").limit, 5)
        @Expect(inputFixture("{\"query\":\"q\",\"limit\":2.5}").limit, 10)
    }
    @TestCase
    func optionalModelLikeFieldsRemainCompatibilityInputs() {
        let input = inputFixture("{\"query\":\"q\",\"max_tokens\":800,\"temperature\":0.2}")
        @Expect(input.maxTokens.getOrThrow(), "800")
        @Expect(input.limit, 10)
    }
    @TestCase
    func autoUsesFixedProviderPriority() {
        let input = inputFixture("{\"query\":\"q\"}")
        @Expect(selectSearchProvider(input, SearchAvailability(brave: true, tavily: true, searxEndpoint: "https://s")), "brave")
        @Expect(selectSearchProvider(input, SearchAvailability(tavily: true, searxEndpoint: "https://s")), "tavily")
        @Expect(selectSearchProvider(input, SearchAvailability(searxEndpoint: " https://s \n")), "searxng")
        @Expect(selectSearchProvider(input, SearchAvailability()), "none")
    }
    @TestCase
    func explicitProviderDoesNotFallbackOrRequestWhenMissing() {
        let result = immediateFixture("{\"query\":\"q\",\"provider\":\"brave\"}",
            available: SearchAvailability(tavily: true, searxEndpoint: "https://s"))
        @Expect(searchText(result, "content"), "Error: Brave is not configured.")
        @Expect(searchText(result, "provider"), "brave")
    }
    @TestCase
    func noneAndUnconfiguredAutoHavePinnedResultShape() {
        for (json in ["{\"query\":\"q\"}", "{\"query\":\"q\",\"provider\":\"none\"}"]) {
            let result = immediateFixture(json)
            @Expect(searchText(result, "content"), "Error: No web search provider configured.")
            @Expect(result.field("count").getOrThrow().asNumberText(), "0")
            @Expect(result.field("sources").getOrThrow().items.size, 0)
        }
    }
}

@Test
class SearchRequestTests {
    @TestCase
    func braveTemplateContainsNoCredentialValue() {
        let request = requestFixture("{\"query\":\"Cangjie & x=y 文档\\nline\",\"provider\":\"brave\",\"limit\":3}")
        @Expect(request.method, "GET")
        @Expect(request.url, "https://api.search.brave.com/res/v1/web/search")
        @Expect(fieldFixture(request.query, "q"), "Cangjie & x=y 文档\nline")
        @Expect(fieldFixture(request.query, "count"), "3")
        @Expect(request.headers.size, 1)
        @Expect(fieldFixture(request.headers, "Accept"), "application/json")
        @Expect(request.jsonBody.isNone(), true)
        @Expect(match (request.credential.getOrThrow().placement) {
            case SearchCredentialPlacement.Header(name) => name == "X-Subscription-Token"
            case _ => false
        }, true)
    }
    @TestCase
    func braveMapsEveryRecencyValue() {
        let inputs = ["day", "week", "month", "year"]
        let expected = ["pd", "pw", "pm", "py"]
        for (index in 0..inputs.size) {
            let request = requestFixture("{\"query\":\"q\",\"recency\":\"" + inputs[index] + "\"}")
            @Expect(fieldFixture(request.query, "freshness"), expected[index])
        }
        @Expect(requestFixture("{\"query\":\"q\"}").query.size, 2)
    }
    @TestCase
    func tavilyBuildsExactJsonBodyWithSeparateCredentialPlacement() {
        let request = requestFixture("{\"query\":\"What is Cangjie?\",\"provider\":\"tavily\",\"recency\":\"month\",\"num_search_results\":3,\"max_tokens\":800,\"temperature\":0.5}")
        @Expect(request.method, "POST")
        @Expect(request.url, "https://api.tavily.com/search")
        @Expect(request.query.size, 0)
        @Expect(fieldFixture(request.headers, "Content-Type"), "application/json")
        let body = request.jsonBody.getOrThrow()
        @Expect(searchText(body, "query"), "What is Cangjie?")
        @Expect(body.field("max_results").getOrThrow().asNumberText(), "3")
        @Expect(body.field("include_answer").getOrThrow().asBool(), true)
        @Expect(searchText(body, "search_depth"), "basic")
        @Expect(searchText(body, "time_range"), "month")
        @Expect(body.field("max_tokens").getOrThrow().asNumberText(), "800")
        @Expect(body.field("api_key").isNone() && body.field("temperature").isNone(), true)
        @Expect(match (request.credential.getOrThrow().placement) {
            case SearchCredentialPlacement.JsonField(name) => name == "api_key"
            case _ => false
        }, true)
    }
    @TestCase
    func tavilyOmitsUnauthoredOptionalFields() {
        let body = requestFixture("{\"query\":\"q\",\"provider\":\"tavily\"}").jsonBody.getOrThrow()
        @Expect(body.field("time_range").isNone() && body.field("max_tokens").isNone(), true)
        @Expect(body.fields.size, 4)
    }
    @TestCase
    func searxUsesConfiguredPathAndExplicitEmptyTimeRange() {
        let request = requestFixture("{\"query\":\"q\",\"provider\":\"searxng\",\"limit\":2}",
            available: SearchAvailability(searxEndpoint: " https://search.example.test/base/ "))
        @Expect(request.url, "https://search.example.test/base/search")
        @Expect(request.method, "GET")
        @Expect(fieldFixture(request.query, "format"), "json")
        @Expect(fieldFixture(request.query, "limit"), "2")
        @Expect(fieldFixture(request.query, "time_range"), "")
        @Expect(request.credential.isNone() && request.jsonBody.isNone() && request.headers.isEmpty(), true)
    }
    @TestCase
    func searxPreservesExplicitRecencyAndAuthorityText() {
        let request = requestFixture("{\"query\":\"q\",\"provider\":\"searxng\",\"recency\":\"year\"}",
            available: SearchAvailability(searxEndpoint: "http://[::1]:8080"))
        @Expect(request.url, "http://[::1]:8080/search")
        @Expect(fieldFixture(request.query, "time_range"), "year")
    }
}

@Test
class SearchResponseTests {
    @TestCase
    func braveGoldenPreservesPresentationAndSourceFields() {
        let result = decodeSearchResponse("brave", "{\"web\":{\"results\":[{\"title\":\"Docs\",\"url\":\"https://x.test\",\"description\":\"Language docs\",\"publishedDate\":\"2026-07-30\"}]}}", 10)
        @Expect(searchText(result, "content"), "[1] Docs (2026-07-30)\n    https://x.test\n    Language docs")
        @Expect(result.field("count").getOrThrow().asNumberText(), "1")
        @Expect(result.field("error").getOrThrow().unifiedKind == UnifiedJsonKind.Null, true)
        @Expect(result.field("sources").getOrThrow().items[0].fields.size, 4)
    }
    @TestCase
    func tavilyAnswerAndSourcesGolden() {
        let result = decodeSearchResponse("tavily", "{\"answer\":\" answer \",\"results\":[{\"title\":\"A\",\"url\":\"https://a\",\"content\":\"Snippet\",\"published_date\":\"today\"}]}", 10)
        @Expect(searchText(result, "content"), "answer\n\n## Sources\n1 source\n[1] A (today)\n    https://a\n    Snippet")
        @Expect(searchText(result.field("sources").getOrThrow().items[0], "publishedDate"), "today")
    }
    @TestCase
    func answerOnlyAndPluralSourcesRemainRenderable() {
        @Expect(searchText(decodeSearchResponse("tavily", "{\"answer\":\"  answer  \"}", 10), "content"), "answer")
        let multiple = decodeSearchResponse("tavily", "{\"answer\":\"A\",\"results\":[{\"url\":\"a\"},{\"url\":\"b\"}]}", 10)
        @Expect(searchText(multiple, "content").contains("2 sources\n[1] a\n    a\n[2] b\n    b"), true)
    }
    @TestCase
    func invalidSourcesDoNotConsumeLimitAndEmptyTitlesUseUrl() {
        let result = decodeSearchResponse("searxng", "{\"results\":[{},null,{\"url\":2},{\"url\":\"one\",\"title\":\"\"},{\"url\":\"two\"}]}", 1)
        @Expect(result.field("count").getOrThrow().asNumberText(), "1")
        @Expect(searchText(result, "content"), "[1] one\n    one")
    }
    @TestCase
    func wrongTypesAndEmptyContentFailExplicitly() {
        for (body in ["{}", "null", "[]", "{\"results\":\"bad\"}", "{\"answer\":3,\"results\":[]}"]) {
            let result = decodeSearchResponse("tavily", body, 10)
            @Expect(searchText(result, "error"), "Tavily returned no renderable search content.")
            @Expect(result.field("sources").getOrThrow().items.size, 0)
        }
    }
    @TestCase
    func malformedJsonRetainsFailureShape() {
        let result = decodeSearchResponse("brave", "{bad", 10)
        @Expect(searchText(result, "content").startsWith("Error: invalid provider response:"), true)
        @Expect(searchText(result, "error").startsWith("invalid provider response:"), true)
        @Expect(searchText(result, "provider"), "brave")
        @Expect(result.field("count").getOrThrow().asNumberText(), "0")
    }
    @TestCase
    func transportFailureUsesStderrOrExitCode() {
        @Expect(searchText(searchTransportFailure("tavily", 22, " HTTP 401\n"), "content"), "Error: HTTP 401")
        @Expect(searchText(searchTransportFailure("brave", 7, " \n"), "error"), "provider request failed with exit code 7")
    }
    @TestCase
    func utf8TruncationNeverSplitsTwoThreeOrFourByteScalar() {
        @Expect(searchTruncateUtf8("éx", 1), "…")
        @Expect(searchTruncateUtf8("éx", 2), "é…")
        @Expect(searchTruncateUtf8("界x", 2), "…")
        @Expect(searchTruncateUtf8("界x", 3), "界…")
        @Expect(searchTruncateUtf8("😀x", 3), "…")
        @Expect(searchTruncateUtf8("😀x", 4), "😀…")
        @Expect(searchTruncateUtf8("é", 2), "é")
        @Expect(searchTruncateUtf8("x", 0), "…")
    }
    @TestCase
    func displayBudgetDoesNotTruncateStructuredSnippet() {
        var prefix = ""
        for (_ in 0..239) { prefix += "a" }
        let snippet = prefix + "界 trailing"
        let result = renderSearchResponse(SearchResponse("searxng", "", [SearchSource("T", "u", snippet, "")]))
        @Expect(searchText(result, "content"), "[1] T\n    u\n    " + prefix + "…")
        @Expect(searchText(result.field("sources").getOrThrow().items[0], "snippet"), snippet)
    }
}

@Test
class SearchCommandTests {
    @TestCase
    func parsesPositionalsAndBothFlagForms() {
        match (parseSearchCommand(["Cangjie", "language", "--provider=brave", "--recency", "week", "-l", "3", "--compact"])) {
            case SearchCommand.Search(input, compact) =>
                @Expect(input.query, "Cangjie language")
                @Expect(input.provider, "brave")
                @Expect(input.recency, "week")
                @Expect(input.limit, 3)
                @Expect(compact, true)
            case _ => @Expect(false, true)
        }
    }
    @TestCase
    func helpNeedsNoQueryOrProviderConfiguration() {
        @Expect(match (parseSearchCommand(["--help"])) { case SearchCommand.Help => true; case _ => false }, true)
        @Expect(searchCommandHelp().contains("axyndra tools inspect plugin.axyndra:web-search.web_search"), true)
        @Expect(searchCommandHelp().contains("axyndra tools invoke plugin.axyndra:web-search.web_search '{\"query\":"), true)
        @Expect(searchCommandHelp().contains("provider: auto, brave, tavily, searxng, or none"), true)
        @Expect(searchCommandHelp().contains("axyndra search") || searchCommandHelp().contains("--provider"), false)
    }
    @TestCase
    func rejectsMissingValuesUnknownFlagsAndInvalidFilters() {
        let cases: Array<Array<String>> = [[], ["--provider"], ["q", "--limit", "0"], ["q", "--limit=1.5"],
            ["q", "--provider=none"], ["q", "--provider=unknown"], ["q", "--recency=forever"], ["q", "--oops"]]
        for (arguments in cases) {
            @Expect(commandRejected(arguments), true)
        }
    }
    @TestCase
    func unsupportedLegacyLabelDoesNotInventProviderRequest() {
        @Expect(match (parseSearchCommand(["q", "--provider=perplexity"])) {
            case SearchCommand.Unavailable(provider, compact) => provider == "perplexity" && !compact
            case _ => false
        }, true)
        @Expect(searchText(searchUnavailableResult("perplexity"), "error"),
            "Search provider \"perplexity\" is not available in this axyndra build.")
    }
    @TestCase
    func duplicateFlagsKeepFirstValueAndLimitIsBounded() {
        match (parseSearchCommand(["q", "--provider", "brave", "--provider", "tavily", "--limit=100"])) {
            case SearchCommand.Search(input, _) =>
                @Expect(input.provider, "brave")
                @Expect(input.limit, 20)
            case _ => @Expect(false, true)
        }
    }
    @TestCase
    func compactRetainsAtMostSixLinesAndShowsOmission() {
        @Expect(renderSearchCompact("one\ntwo"), "one\ntwo")
        @Expect(renderSearchCompact("1\n2\n3\n4\n5\n6"), "1\n2\n3\n4\n5\n6")
        @Expect(renderSearchCompact("1\n2\n3\n4\n5\n6\n7\n8"), "1\n2\n3\n4\n5\n6\n…")
    }
}
