# Logical JSON allocation and transport

This library is the single owner of the original logical JSON bank, shared
lease high water, fixed-ticket display copies, bounded framing and pure JSON
profile functions. It depends on yjson/yjson_support and the same pinned SDK
digest primitive; it has no Agent, Source, policy, Host, filesystem or process
dependency. The original 128 MiB default aggregate, 16 MiB floor, 32 transfer
ceiling, two worker transfers, 16 KiB chunks and private actual-bank custody
are unchanged. The caller still owns real data/physical retirement.

Domain names are real type aliases to these concrete objects. Allocation
failure categories adapt to the original Domain error fields. Generic display
borrows return the caller's whole result object unchanged. Neither allocations
nor errors authorize I/O or establish a Source. No finalizer refunds debt.

Existing Domain/provider tests are retained, with a Domain identity/error
control and an independent Domain-only importing consumer in
support_tests/neutral_payload_consumer126. Source review and offline gates do
not establish SDK compilation, Root acceptance or capacity completion.
