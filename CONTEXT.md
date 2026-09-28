# Axyndra Runtime

The runtime coordinates model turns and mediated tool work while preserving each invocation’s authority and lifecycle.

## Operations

**Root Tool Operation**:
A top-level invocation admitted from a validated, canonically committed tool call. Program work stays within its authority and lifecycle.

**Derived Tool Operation**:
An internal tool call issued by a running program under a Root Tool Operation. It has separate evidence, but is not a new model decision or user-visible turn.

**Tool Program**:
A bounded program that coordinates read-only calls admitted by the host under one Root Tool Operation. It has no independent authority over host resources.

## Plan application

**Application Plan**:
An immutable, host-stored proposal binding one read-only Program result to exact workspace targets, expected file states, and replacement-content digests. It describes a possible effect but grants no authority.

**Intent Confirmation**:
A separate direct canonical request that starts a new Root Tool Operation for
one exact plan. It is not a Derived Tool Operation and grants no capability or
satisfies any required approval.

**Application Authorization**:
The host's authority to execute one prepared plan, based on current policy and
capability checks plus any required approval. It is bound to the exact plan and
grants no additional capability.
