# Skill discovery and pre-Run routing

`ProductSkillRuntime` discovers installed Skill metadata and resolves a fresh
`SkillStackSnapshot` before each Run. It does not select tools, grant capabilities,
change approval policy, or relax the sandbox. There is no Run-internal Skill
activation/deactivation API.

## Selection

A non-empty caller-provided snapshot wins without re-reading instructions. Next,
explicit `$<skill-id>` or `$<skill-name>` mentions select only the named Skills;
automatic selection never adds to that set. Existing case-sensitive, longest-name
and Unicode marker boundaries are preserved. An unresolved or malformed dollar
mention does not silently fall back to automatic selection. Conservatively, any
prompt containing `$` disables the automatic fallback, including shell snippets.

Otherwise the Product router scores metadata using deterministic lexical rules:

- A complete ID/name phrase scores 8; a complete trigger phrase scores 6.
- At least two distinct matching description terms score 2–4. Repeating a term
  does not increase the score. Stop words such as `please`, `the` and `skill` are
  ignored, and ASCII matching is case-insensitive.
- Up to three positive-scoring candidates are selected, ordered by descending
  score and then ascending Skill ID. Zero matches produces an empty stack.

This is not an embedding model or cross-language semantic search. Non-ASCII text
is retained without byte slicing; authors should supply matching-language names,
descriptions or trigger phrases. An explicit mention is the reliable override.
Automatic routing is skipped for prompts exceeding 32 KiB; explicit selection is
still available. Each routing field is also limited to 512 meaningful terms; an
over-budget field contributes no matches, rather than matching a truncated
prefix. Only the selected instruction bodies are loaded. Missing,
invalid or oversized bodies fail activation and are not replaced by unrelated
Skills. The existing snapshot return API does not surface a separate diagnostic
for an individual failed activation.

## Discovery and budgets

The configured roots remain `managed-skills`, user `skills`, and workspace
`.omp/skills`, in increasing override priority. Among inspected candidates,
identity conflicts are resolved before the final catalog budget is applied, so a
budget cannot resurrect a shadowed lower-priority definition.

Discovery inspects at most the first 128 sorted Skill directories per root. Each
frontmatter read consumes at most 4 KiB and stops at the closing `---` line,
including its newline. Both LF and CRLF work. Missing, unterminated, oversized or
invalid UTF-8 headers are skipped. A closing delimiter must have a newline; the
bounded reader never consumes the following instruction body to validate it.
The existing simple, single-line frontmatter subset remains unchanged; this is
not a general YAML parser or a new ecosystem format.

The admitted catalog has at most 128 entries and a conservative 64 KiB rendered
metadata budget. Later/higher-priority entries are admitted first. The fixed
catalog header is charged per entry to keep the budget conservative. References
remain metadata only, with the existing limit of 32 declared references per Skill.
Files retain the 64 KiB content limit; actual activation/reference reads enforce
the limit as well as the preliminary file stat.

These limits bound header reads, loaded candidates and rendered metadata, not the
underlying shallow directory enumeration needed to obtain a deterministic sorted
order. The sort retains only the bounded candidate/reference name sets. Discovery does not recursively scan the workspace or load references.
`metadata()` and `resolve()` still refresh discovery separately; no persistent
index, filesystem watcher or metadata cache is introduced by this change.

## Lifetime, recovery and references

The selected instructions are copied into the existing Run launch snapshot. A
file edit cannot change an already-created snapshot. A later Run resolves again;
an unrelated task receives no active Skill. Recovery continues to use the frozen
snapshot rather than rerouting against changed files.

`SkillStackSnapshot.loadedReferences` is **launch-time, caller-preloaded data** in
the Product path. A `read_skill_reference` call returns ordinary durable tool
output. It does not mutate that launch snapshot. The generic `SkillStack` builder
may accumulate references before a caller takes a snapshot, which is a distinct
construction-time operation. On-demand reference reads retain the existing live
file-read semantics; their observed output, not a later reread, is the history
used for replay. Historical tool outputs and summaries are not erased when a
Skill is absent from a later Run.

## Prompt cache contract

Skill instructions remain in the dynamic, per-Run context. `PromptBuilder`
continues to order sections as Stable → Session → Turn, and changing a Skill does
not change `stablePrefix` or its hash. No provider adapter, cache routing policy,
capability snapshot or recovery schema is changed.

A stable cache key is **not** proof of an actual provider cache hit. Skill
instructions are still included in the system context before conversation
messages. Changing those earlier tokens can reduce reuse of the following
history on a prefix-caching provider. This change preserves the existing stable
prefix contract; it does not promise cache-free Skill switching or full-history
reuse.

## Validation

`agent_product/src/skill_routing_test.cj` covers routing, explicit precedence,
ranking, zero matches, Unicode, header read boundaries, malformed headers, actual
content read limits and metadata budgets. It is included in
`scripts/product_unit_inventory.json`.

`support_tests/product_prompt_contract` covers filesystem-backed discovery,
frozen instructions across edits, lazy reference semantics, automatic activation,
subsequent-Run removal and stable cache-key preservation at the ModelRequest
boundary. Existing Skill, Core, SDK and recovery contracts remain applicable.
