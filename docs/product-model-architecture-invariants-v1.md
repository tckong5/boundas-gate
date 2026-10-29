# Boundas Gate — Product Model / Architecture Invariants v1

For the shared-login/transport ownership direction and independent Gate routing, see the [Shared Tunnel architecture target](shared-tunnel-architecture-target.md) and its [implementation report](shared-tunnel-implementation.md). This contract records the underlying v1 semantics.

## Core invariants

> A Gate can exist with zero Folders.
>
> A Gate can be Open with zero MCP Connections.
>
> A Folder may belong to Main Gate, have a Side Gate, or both.
>
> Removing a Side Gate never removes the Folder or changes Main Gate state.

An implementation that contradicts these invariants is a regression, not a reason to reopen the UX contract.

---

## 1. Core model

A Gate is an independently managed MCP endpoint with its own lifecycle and authorization boundary. It is distinct from both a Folder and a Tunnel.

```text
Gate
├── Tunnel
├── 0..n MCP Connections
└── 0..n Folder Access
```

Main Gate:

```text
1 Gate → 0..n Folders
```

Side Gate:

```text
1 Gate → exactly 1 Folder
```

A Folder can belong to both:

```text
Main Gate ✓
Side Gate ✓
```

Their connection states must remain independent.

---

## 2. Gate existence is independent of Folders

A Gate must operate normally with zero Folders. Both states are valid:

```text
Gate Open
0 MCP Connections
0 Folders shared
```

```text
Gate Open
2 MCP Connections
0 Folders shared
```

An AI call returning `list_workspaces → []` is normal, not an error.

Folders must not be prerequisites for Gate startup, a Tunnel, MCP authorization, or reconnection. Removing the final Folder must not automatically decommission the Gate.

---

## 3. Runtime Gate status

Do not represent every concern with one Ready boolean. Runtime states include:

- Gate Open
- Gate Closed
- Opening Gate…
- Reopening Gate…
- Gate Needs Attention

**Gate Open = healthy Gate endpoint + healthy required transport/Tunnel.**

MCP Connections and Folder sharing are separate information:

```text
● Gate Open
2 MCP Connections · 0 Folders shared
```

Zero Connections or Folders do not imply Gate Closed. Ready can remain a first-run/setup milestone, but must not become the core runtime state.

---

## 4. Setup journey

First-run setup can remain:

```text
Local
  ↓
Tunnel
  ↓
MCP Connection
  ↓
Ready
```

This is a setup journey, not the Gate state machine. An open Gate without authorization can show:

```text
Gate Open
0 MCP Connections
[ Set Up MCP Connection ]
```

---

## 5. MCP Connection

Use **MCP Connection** for the authorization relationship between an external MCP client and one Gate:

```text
ChatGPT       Authorized
Claude        Authorized
Other Client  Invalid
```

Authorized does not imply a current live session. Do not use Connected/Disconnected without actual runtime-session evidence.

Each authorization belongs to **one Gate**:

```text
Main Gate authorization
≠
Side Gate A authorization
≠
Side Gate B authorization
```

Authorization cannot be reused across Gates.

---

## 6. Folder

Use **Folder** consistently in ordinary UI instead of mixing Workspace and Repository. Repository is appropriate only for genuinely Git-specific functionality. Internal code can retain `WorkspaceRecord`; terminology alone does not require an immediate model rename.

---

## 7. Side Gate membership

```text
Folder exists
        ≠
Side Gate exists
```

`sideGateAdded` must govern real Side startup, refresh, reconnect, diagnostics, counts, and lifecycle operations, not just sidebar visibility. Main-only Folders must not be touched by Side batch startup/reconnect.

---

## 8. Remove Side Gate

The action is **Remove Side Gate**, not Remove Workspace. It decommissions an independent Gate without deleting the Folder.

```text
Active
  ↓
Removing…
  ↓
stop Side Gate
revoke Side Gate authorization
retire active tunnel/route
clear runtime credentials
  ↓
sideGateAdded = false
```

Preserve:

- Folder identity/path/name
- Main Gate membership
- Main Gate sharing state
- Passcode policy
- Preferred Tunnel provider

Clear or invalidate:

- Side Gate MCP authorizations
- Pairing secrets
- Temporary credentials
- Runtime diagnostics
- Active endpoint binding
- Configured active MCP URL

`lastKnownURL` and provider/domain reservation identity may remain as historical/configuration metadata only, never as an active endpoint.

If removal fails, retain the Gate with **Removing Failed → Retry**. Never hide it while leaving orphaned runtime state.

---

## 9. Passcode

The policy adopted in the 2026-10-08 security review is:

**Passcode Protection = Folder-level policy.**

```text
Folder A
Passcode Protection ON
```

Every Gate exposing Folder A must obey the same policy:

```text
Main Gate → Folder A
Side Gate → Folder A
```

The UI mental model is “this Folder has extra protection.” Allowing Side to bypass Main's Passcode requirement would violate that expectation. A future Gate-Folder policy is possible if needed, but v1 avoids that complexity.

Main and Side reuse `FolderAccess` generation/unlock/expiry/revocation. Passcode ON does not permanently disable Side access. Side-only Folders have a policy without needing Main sharing.

Temporary unlock is **not a global Folder unlock**. Every access key must match:

- Gate ID, with independent AuthStore/code/key storage per Gate.
- OAuth credential hash; refresh or credential replacement does not automatically inherit a key.
- Folder ID, membership epoch, and policy epoch.
- Conversation metadata; when the app supplies none, explicit `session_id`, still requiring the matching OAuth credential and access key.
- A maximum of 30 minutes, never exceeding OAuth access-token expiry.

Passcodes expire after five minutes and are single-use. Generate New Code/Invalidate/Revoke clears that Gate's Folder codes/grants. Policy toggles change the shared policy epoch, invalidating previous grants across Main and Side. Gate restart clears temporary codes/grants while retaining persistent OAuth authorization.

Protected operations, including Git/execution reads, recheck ACL/policy/grant before and after work. A Main key cannot unlock Side access. See [security-robustness-review.md](security-robustness-review.md).

---

## 10. Tunnel

A Tunnel provides **external reachability to a Gate**. OAuth, MCP authorization, Folder ACLs, Passcodes, and Gate identity belong to Boundas Gate Core.

```text
Gate Core
   ↓
Tunnel Layer
   ↓
TunnelProvider
   ├── Tailscale
   ├── ngrok
   └── future providers
```

The provider diagram includes future options. Each v1 Gate binds to one active provider. Transparent hot-switching is not implemented; changing providers is endpoint migration.

---

## 11. TunnelProvider abstraction

Freeze ownership boundaries first rather than extracting a complete framework before an ngrok spike. Extract the common interface during that spike.

Minimum operations:

- prepare
- start
- stop
- status
- endpoint

Possible capability reports:

- stableEndpoint
- customDomain
- interactiveLogin
- perGateEndpoint
- sharedIngress

The Gate coordinator owns reconnect policy, desired-running intent, and retry/backoff. Providers should not each manage those independently.

---

## 12. Product terminology

- Folder
- Gate
- Main Gate
- Side Gate
- Tunnel
- MCP Connection
- Passcode Protection

**Gate** = independently managed MCP endpoint + authorization boundary + lifecycle.

**Tunnel** = external reachability mechanism.

**MCP Connection** = external MCP client authorization to one Gate.

**Folder** = resource exposed through a Gate.

---

## 13. Original implementation priorities

1. **Freeze these semantics.**
2. **Fix Side lifecycle:** enforce `sideGateAdded` across start/stop/reconnect/refresh/remove.
3. **Add Side tests alongside implementation**, not afterward.
4. **Support zero-Folder Gates:** remove Folder prerequisites across backend/server/launcher/reconnect/UI.
5. **Unify user-facing terminology:** Folder/Gate/Tunnel/MCP Connection.
6. **Run an ngrok spike:** first verify stable endpoints, OAuth callbacks, streaming, restart, and multiple Gates.
7. **Extract a minimal TunnelProvider during the spike.**
8. **Then implement provider selection/migration UI.**
