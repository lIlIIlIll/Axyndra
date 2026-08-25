# LLM provider runtime

Axyndra keeps four different concepts separate below `ModelPort`:

- A **Provider Profile** is one configured endpoint, credential source, default-header set, and model catalog. `deepseek-openai` and `deepseek-anthropic` are different profiles even when they belong to the same vendor.
- A **Model Descriptor** binds a stable `profile/model` name to a wire model id, an API id, immutable execution capabilities, and output limits.
- A **Wire API** is the complete request, response, streaming, tool-call, and terminal contract. The built-in registry contains OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages adapters.
- A **typed dialect** contains only the compatibility switches relevant to its API. `OpenAiCompletionsDialect.DeepSeek` cannot be attached to an Anthropic Messages binding.

Their relationship is explicit and orthogonal:

    Provider Profile
        -> offers/selects Model
        -> Model declares Wire API through model.apiId
        -> Wire API may be parameterized by its own typed dialect

Provider brand is not a protocol. For example, `deepseek-openai/deepseek-v4-flash`
declares the OpenAI Chat Completions API and a DeepSeek completions dialect. DeepSeek
does not become a separate Wire API merely because it changes `max_tokens`, thinking
lowering, or reasoning replay.

## Dialect or new adapter?

A difference is a **dialect** when it can be expressed through request/response field
mapping, capability switches, and limited replay rules without changing the protocol
state machine. A structural change to the request model, streaming state machine,
tool-call lifecycle, or terminal/continuation semantics is a **new Wire API** and
requires a new `LlmApiAdapter`.

| Difference | Typed dialect | New adapter |
| --- | :---: | :---: |
| `max_tokens` versus `max_completion_tokens` | yes | |
| Different `reasoning_effort` field or value mapping | yes | |
| `thinking: {type: ...}` lowering | yes | |
| `reasoning_content` replay | yes | |
| Tool results require `name` | yes | |
| Different SSE field names with the same state machine | usually | |
| Structurally different message JSON model | | yes |
| Structurally different tool-call lifecycle | | yes |
| Different streaming state machine | | yes |
| Different terminal or continuation model | | yes |

Typed dialects are scoped to one Wire API. They must not grow into a global
compatibility bag containing alternative message schemas, tool protocols, streaming
state machines, or terminal models. Once one of those boundaries changes, the new API
owns its complete lowering and parsing path:

    canonical ModelRequest
        -> API-specific request lowering
        -> HTTP/SSE
        -> API-specific raw events
        -> canonical ModelEvent
        -> normalized provider result

The resulting rules are:

- Same protocol, different provider: reuse the adapter with an API-specific typed dialect.
- Same provider, different protocol: use a different explicit `model.apiId`; profiles may belong to the same provider family.
- Completely different protocol: add a new API id and `LlmApiAdapter`.
- Unknown API id: fail closed.
- Protocol selection comes exclusively from `model.apiId`.
- Provider-name, model-name, and endpoint-URL heuristics are forbidden.

The complete production path is:

    AgentCore -> ModelPort -> UnifiedModelRuntime
              -> RuntimeProviderProfile + RuntimeModelDescriptor
              -> LlmApiAdapterRegistry -> protocol adapter
              -> ProviderModelPort -> llm4cj HTTP/SSE transport

`agent_core` never sees provider DTOs or HTTP/SSE state. `llm4cj` remains transport-only and does not import Agent domain types. An absent API id, or an API/dialect mismatch, fails before credential resolution or network I/O; the runtime never infers either from a provider name, model name, or URL.

## Configuration and migration

Existing `providers.yml`, `models.yml`, profile/model identifiers, setup output, and session selection remain valid. The loader converts the existing explicit `protocol` and `dialect` fields into typed runtime bindings. A model may additionally declare `api` and `dialect`, allowing one profile to dispatch different models through different APIs. New canonical model entries use values such as:

    api: openai_chat_completions
    dialect: deepseek_chat

Other API ids are `openai_responses` and `anthropic_messages`. Ambiguous or incompatible combinations fail closed. Secrets remain credential references or resolved runtime values; they are not copied into model requests, sessions, or diagnostics.

Profiles and models may declare typed `default_headers` entries such as
`["x-route: canary"]`. Header precedence is profile, then model, then adapter-owned
request headers. Authentication and transport-control headers are not part of that
merge: `authorization`, `x-api-key`, cookies, host, content length, CR/LF, and invalid
header names are rejected before persistence or I/O. Credentials are resolved per
profile and per request; cancellation reaches both credential resolution and an
already-dispatched provider request.

To add an OpenAI-compatible profile, reuse `OpenAiChatCompletionsAdapter` and select an existing typed dialect or add a narrowly scoped `OpenAiCompletionsDialect`. To add a new Wire API, implement `LlmApiAdapter`, register its stable API id in the composition root, and keep canonical request/result conversion in that one adapter. If providers or endpoints have same-protocol variations, define an API-specific typed dialect; otherwise use the API's standard dialect/config. Do not fork an encoder per provider or disguise a new protocol as compatibility switches on an existing adapter.

## DeepSeek behavior

The official OpenAI-compatible DeepSeek binding uses the Chat Completions adapter with the DeepSeek typed dialect. It emits `max_tokens`, lowers the explicit thinking toggle and supported reasoning effort, replays assistant `reasoning_content`, and reads `completion_tokens_details.reasoning_tokens`. Reasoning tokens are validated as a subset of completion tokens rather than added to completion usage again. The raw finish reason is retained, while `max_tokens` and `length` normalize to `OutputLimited`.

Normalized usage records whether it came from a non-stream provider response, a
stream-final usage event, or an estimate. Provider-final usage carries typed evidence:
protocol, terminal event kind, and provider response id when present. The same evidence
survives Agent events and durable Decision usage; old records without these fields
decode as `Unknown` rather than fabricating provenance.

The request output reserve is the number of tokens kept for a complete final answer or tool call plus terminal framing. The compatibility field `minVisibleResponseTokens` now has the explicit alias `decisionReserveTokens`. Numeric thinking budgets must fit beside that reserve. Effort-only models record the selected effort but cannot claim a hard reasoning-token guarantee.

## Decision boundary and recovery

A provider stop reason is evidence, not a Decision. An output-limited stream without an accepted Decision is classified as `OutputLimitedBeforeDecision`. Partial text, reasoning, and tool arguments stay diagnostic; scratch JSON and incomplete blocks never become durable canonical tool calls and are never dispatched.

Recovery uses the existing Attempt lifecycle. It creates a bounded child Attempt, preserves the original requested policy and source, adds a typed `recoveryCeiling` derived from the model's actually supported thinking levels, resolves the exact child policy, and persists it before provider I/O. A successful child Attempt is the only source of executable tool calls. Exhaustion reports `model.output_limited_before_decision` with attempt, terminal, usage, boundary, and recovery evidence instead of hiding the root cause behind the decision-terminal invariant.

This ordering is a transaction boundary: **resolve immutable capability snapshot and policy -> persist Attempt -> perform provider I/O -> validate an atomic Decision -> hand off tools**. Moving I/O before persistence, or accepting a partial tool call before the terminal is known, breaks replay and exactly-once safety.
