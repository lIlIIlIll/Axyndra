# Independent Memory policy

This native package contributes the pure `memory` Provider. It depends on the
shared `pure_provider_runtime` wire and has no Host, Product, Store, filesystem,
model, network, or service capability. The Host sends already-authorized facts;
the package proposes ranking, untrusted context text, or correction defaults.

The `axyndra.memory-policy/v1` input actions are `retrieve`, `context`, and
`correct`. Each request and response carries the Host snapshot digest. Retrieval
returns only exact IDs/revisions and integer scores/ranks. Correction returns
the selected record ID/revision plus replacement fields; the Host independently
enforces the original user changes, scope, current record and durable CAS.

Lexical phrase/token/context scoring, importance, recency/ID tie breaks, hybrid
reciprocal-rank fusion, explicit embedding-failure fallback, and the eight-row
UTF-8 context renderer preserve the former Product algorithms. No embedding
adapter means lexical ranking without a false fallback indication. Embeddings
are observed facts from an explicitly supplied trusted Host adapter; this
package cannot request an embedding model or create network authority.

Select the actual installed package in `plugins/policies.json`:

```json
{"version":1,"bindings":{"memory":{"namespace":"axyndra:memory","provider":"memory","package_digest":"sha256:<actual-package-digest>"}}}
```

The Coding distribution installs and enables this package through the normal
registry only if no operator record exists. Existing operator policy files,
disabled records, and independently updated versions are retained.

The shared pure-content profile limits a JSON query to 4,456,448 bytes and its
result to 4,194,304 bytes, with the same token/aggregate reservations and fixed
deadline as other pure providers. A larger authorized record set is rejected
explicitly; it is never silently truncated. Immutable multi-page query facts
are still required for parity with arbitrarily large existing memory stores.
This candidate does not claim that capacity gap or remote embeddings are done.

`scripts/prepare_memory_plugin.py` builds a fresh relocatable package and checks
all 12 actual native protocol cases. Product tests separately cover real SQLite
records, canonical Direct/Committed tool results, normal selection, cancellation,
stale facts, correction history and Coding defaults. These tests are authored;
no Cangjie build or execution has been performed for this external candidate.
