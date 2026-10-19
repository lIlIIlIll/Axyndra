# Explicit read-view preparation input references

The Native Workspace write selector accepts an explicit transport opt-in in the existing `settings/plugins/services.json` package record:
`"read_view_parameter_references": ["write"]`.
This field changes preparation transport only. Keep ordinary readonly grants on `read`, `grep`, and `glob`; granting readonly `write` intentionally denies `file.plan.propose`.

The Host sends `axyndra.read-view-parameter-input/v1` with one `reference`: exact actual thread/run/epoch/call/tool/package/generation/configuration binding, complete original canonical UTF-8 input size and SHA, and a neutral typed tree. Every original field and list position is represented; null, missing, duplicate, unknown, and nested fields are never filled in or treated as Workspace grammar. Scalars have type/UTF-8 length/hash/NUL metadata; bounded small values retain their original value. Larger text retains only metadata.

Native preparation validates its own argument grammar and the original 32768-byte write content limit, then describes `request.input_reference`. The Host accepts only its exact captured reference and recomputes it from the original input; it replaces that descriptive field with only the original `request.input`. Actual Native execution validates the complete original content again. The reference grants no Source, permission, Root, file locator, or replay.

Without explicit opt-in, the existing `{input: original}` prepare wire remains unchanged. Unsupported opt-in contributions reject explicitly. Prepare input/output remain 16384/65536 bytes; ordinary frames remain 262144 bytes; frozen worker input remains 229376 bytes. The 32768-byte content ceiling, process deadlines, service allowlists, canonical approval, resource snapshot, CAS, and cleanup requirements are unchanged.

This source candidate is not executed. Acceptance requires the fresh current Native package's original 37 plus 6 protocol cases, the original Workspace Product 10 and Host 2, new reference controls, formatter control and real CLI 11, with complete current-source/SDK/pins/artifact guards.


Installed package identities use the existing publisher's `sha256:` tag plus 64 lowercase hexadecimal digits. Native preparation calls the existing public package identity validator for that field; configuration and original input digests remain raw 64-digit SHA values. A real packaged protocol control checks the tagged positive and rejects untagged, wrong-case, short and non-hex identities. The exact protocol inventory is original37 + reference5 + package-tag1 = 43.

This minimal candidate keeps the original Native main/protocol and all worker modes byte-identical. Static wire-shape review corrected an earlier overestimate: a 32768-byte control-character content produces about230KiB after embedding the original worker JSON in the Host stdout string, within the existing262144-byte frame. Host execution receives only the original input; the durable canonical parent keeps both original input and frozen request input. The former compact-worker WIP3/4 proposals remain preserved, source-only and unused. No compact protocol, quota change or duplicate removal is included here. Static encoding examples do not replace real Cangjie/Native/Root gates.
