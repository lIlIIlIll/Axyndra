# Native Memory snapshot and allocation custody

This component is authored source, with zero Cangjie compilations or executed
cases. It does not establish Host Source, Receipt, approval or effect acceptance.

The actual memory_live provider opts into sharedCustody. A single original
LogicalJsonOwnerReservation retains the original 16 MiB floor and one slot in
the unchanged 128 MiB / 32-owner pool. Real history, decoder, per-record builder,
replay, snapshot and output allocations derive children from that reservation.
The private Domain ledger adds their concurrently retained declared peaks and
1024 bytes per live ledger entry. It keeps the real physical high-water charge
until the last child closes; parent close does not refund a live producer.
Independent logical owners and fixed buffers still pressure that same pool.

Every independently decoded content/context/source chunk contributes its byte
length to the persistent history SUM. A separate frame child reserves eight
times the current record's text bytes plus 1 MiB before builder append, toString
and original field SHA input copies. The record constructor adopts the resulting
immutable Strings. Actual builders are cleared before that child closes. All
metadata String bytes and the existing 8192 per-record cell/clone allowance stay
paid through detached journal/current/policy records, replay and output join.
The collector's extra 1 MiB covers bounded transient lexical scalar work.
Shared replay uses that already-held per-record allowance before making arrays;
it does not add the same cell allowance a second time. Legacy constructors keep
their previous collector and reservation paths.

The unchanged memoryV3Detached constructor passes content, context and source
directly to the new MemoryV3Record. It contains no StringBuilder, fromUtf8,
toArray or serialization call. Cangjie immutable String values are forwarded;
conflictIds are still separately cloned. The current/source arrays and record
objects are separate cells already included in the retained per-record allowance.
The producer's value cells refer to these held Strings; the actual history owner
is retained until output.close physically joins its Future and clears the DOM.
The new test also checks the shared scope reference and independently detached
mutable conflict IDs. Independent decoded current/history bodies are never
deduplicated by value, hash, maximum scalar or number of references.

The live journal keeps its original lock, policy callback, current/snapshot
comparison and result/revision/expiry checks. It internally chooses a paid
snapshot implementation only when given a pure allocation owner. No caller hash
callback is accepted. The snapshot hasher emits the exact original outer list
grammar: opening bracket, original canonical-byte length and colon for each
original memoryV3RecordValue in array order, its complete original canonical
bytes, then closing bracket. A 64 KiB SHA sink and one temporary record DOM are
paid before allocation. The original lexical object-field ordering, length
framing, UTF8, number text, booleans, nulls and nested values are unchanged.
No complete corpus DOM, canonical String or hash input byte array is allocated.

New controls preserve all old116 case names, source bytes and oracles, including
the old default collector's negative diagnostic. The new positive uses 4096
independent 16380-byte Strings, 67092480 total body bytes, original v3 record
writer/framing and actual reflect. A full uniquely matching token selects one
record; the original business method on that original record is the complete
output-byte/hash oracle. Both current/snapshot digests traverse all4096 global
records. The test retains an independent real fixture owner and checks retirement
only after original producer join. Another independent owner causes actual SUM
capacity rejection and complete phase cleanup. Three Domain controls exercise
SUM, parent-close lifetime and independent owner/fixed-buffer pressure.

The original64 MiB bound is per record body in the v3 decoder, and every body
here is under64 KiB. PluginDocumentLatestJournalStreamReference requires a
positive whole extent and exact digest; it imposes no aggregate64 MiB ceiling.
The 64 KiB upload bound, original8 MiB slot/input bounds, original depth and
lexical shape constraints remain unchanged. No aggregate business cap is added.

Caller DTOs outside the provider lifetime require their own real custody. A
single giant scalar still needs its actual builder/final/hash overlap paid and
may correctly exceed the same original pool; these controls do not prove that
all63 MiB single-scalar correction/context branches are closed. Real compilation,
both large controls, complete Host integration and all17 package checks remain
open until the root obtains actual evidence.
