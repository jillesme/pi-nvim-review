# pi-nvim-review project plan

This document is the product and architecture roadmap for `pi-nvim-review`. Each planned change has a stable `PNR-*` project ID.

## Product goal

Give Neovim users a fast, local, and retry-safe way to send a precise code review to a live Pi session.

The primary job is:

> While I inspect code, let me capture contextual questions and change requests, review the batch, and send it to the correct Pi session without losing work.

The plugin is a local reviewer-to-agent handoff. It is not currently a general chat client or a collaborative pull-request review system.

## Planning baseline context

### Strengths

- Line and range comments become one structured message with paths, current ranges, source excerpts, and comments.
- Extmarks follow buffer edits and keep comments attached to relevant code.
- Failed delivery keeps pending comments for retry.
- A busy Pi session queues the review instead of interrupting its current work.
- The bridge uses loopback TCP, a random access token, canonical root and session checks, strict request validation, bounded wire data, and restrictive manifest permissions.
- Neovim has no Lua plugin dependency and provides safe default mappings plus `<Plug>` targets.
- A project can replace the default review instructions with `.pi/nvim-review-prompt.md`.

### Main product problems

- Comments exist only in memory. Neovim exit or failure loses an unfinished review.
- There is no overview in which a user can inspect, edit, delete, or jump to one comment.
- `:PiClear` removes all comments without confirmation.
- Pending comments block session selection. A dead Pi session can therefore trap a valid review.
- First use requires installation in two tools, `/nvim`, matching roots, `:Pi`, and session selection.
- The user cannot easily see bridge health, the active session, submission state, or pending comment count.
- Submission has no preview or warning for excerpts from modified buffers.
- Configuration is limited to timeout and registry directory.
- Only existing project files and line ranges can receive comments.

### Current architecture

Pi side:

- `extensions/nvim-review/index.ts` owns one bridge and sends or queues Pi messages.
- `extensions/nvim-review/bridge.ts` owns TCP connections, authentication, manifest lifecycle, prompt construction, and delivery calls.
- `extensions/nvim-review/protocol.ts` validates requests and responses.
- `extensions/nvim-review/registry.ts` publishes session manifests.

Neovim side:

- `lua/pi_nvim/init.lua` owns the main workflow and active-session state.
- `lua/pi_nvim/annotations.lua` owns comment records and extmarks.
- `lua/pi_nvim/registry.lua` discovers sessions.
- `lua/pi_nvim/client.lua` owns transport.
- `lua/pi_nvim/modal.lua` owns modal input and selection.
- `plugin/pi_nvim.lua` is the command and mapping adapter.

### Main architecture risks

- A submission can reach Pi before its acknowledgement reaches Neovim. A retry can send the same review twice.
- Bridge shutdown destroys sockets but does not cancel or drain request handlers that are waiting for prompt I/O or delivery.
- Broad booleans do not describe bridge and client lifecycle transitions precisely.
- A generic ping failure can remove a valid manifest after a temporary timeout.
- The custom project prompt and final formatted prompt have no explicit size bound.
- Lua does not enforce all server limits before it builds a request.
- Custom registry files need stronger ownership, permission, and symlink checks.
- The protocol has no typed errors, submission identity, capability negotiation, or independent versioning.
- `bridge.ts` and `init.lua` contain responsibilities that can move to focused modules after correctness work is complete.

## Decisions

### Delivery order

Architecture correctness comes first. Review persistence must not preserve an ambiguous or duplicate-prone submission state. The first product work then follows this order:

1. review-loss prevention;
2. comments overview and management;
3. automatic selection of a sole valid session.

Small product improvements can ship with their required architecture work, but they must not delay delivery and lifecycle correctness.

### Comments overview command

Use `:PiComments` for the review overview. It is direct, easy to discover, and consistent with `:PiAnnotate`, `:PiSubmit`, and `:PiClear`.

The first version of `:PiComments` will show:

- project root and target session;
- bridge health and submission state;
- pending comment count;
- file paths, current ranges, and full comment text;
- modified-buffer state;
- actions to jump, edit, delete one, preview, submit, or close.

Do not name the first version an “inbox.” The data is a local pending review, not received messages. Product text can call it the **review overview**.

### Persistence rules

- Store drafts by canonical project root.
- Use an atomic, versioned data format.
- Never persist bridge access tokens.
- Preserve stable comment IDs and submission snapshots.
- Require fresh authentication to a live bridge after restoration.
- Never move a draft to another project root implicitly.
- Permit an explicit rebind only to an authenticated session for the same canonical root.

## Delivery roadmap

Status values are `planned`, `active`, `blocked`, and `done`. Milestone status is recorded on each completed item.

### Milestone 1 — Delivery and lifecycle correctness

These items are prerequisites for safe persistence and retry.

#### PNR-001 — Duplicate-safe submission identity

- **Status:** done
- **Type:** Architecture
- **Priority:** P0
- **Depends on:** none
- **Scope:** Add a stable `submissionId` to each immutable submission snapshot. Echo it in acknowledgements and keep a bounded bridge-side result cache.
- **Reason:** Pi can accept a message before the TCP acknowledgement reaches Neovim. A retry must not send the same review twice during one bridge lifetime.
- **Acceptance:** Retrying the same snapshot and ID returns its prior result without another Pi delivery. Neovim clears only IDs from the acknowledged snapshot.

#### PNR-002 — Serialized delivery and stable retry snapshots

- **Status:** done
- **Type:** Architecture
- **Priority:** P0
- **Depends on:** PNR-001
- **Scope:** Allow one active submission per client or return a typed busy result. Keep the submitted snapshot immutable until acknowledgement or explicit cancellation.
- **Reason:** Concurrent submission and mutation can make acknowledgement and cleanup ambiguous.
- **Acceptance:** Concurrent submit attempts have deterministic results. New comments cannot change an in-flight snapshot.

#### PNR-003 — Explicit lifecycle states and safe shutdown

- **Status:** done
- **Type:** Architecture
- **Priority:** P0
- **Depends on:** none
- **Scope:** Use explicit bridge states such as `starting`, `running`, `stopping`, and `stopped`, and client states such as `disconnected`, `connecting`, `ready`, `submitting`, and `stale`. Track request handlers and cancel or drain them on shutdown.
- **Reason:** A handler can currently continue after bridge shutdown and deliver a message after bridge state became inactive.
- **Acceptance:** No submission can start after shutdown begins. In-flight work is cancelled or drained by a documented rule. State transitions centralize cleanup.

#### PNR-004 — Typed protocol results

- **Status:** done
- **Type:** Architecture
- **Priority:** P0
- **Depends on:** PNR-001, PNR-003
- **Scope:** Replace free-form protocol failures with bounded fields such as `code`, `retryable`, `sessionId`, and `submissionId`.
- **Reason:** The client must distinguish authentication failure, stale session, incompatible version, invalid data, busy state, timeout, and internal failure.
- **Acceptance:** UI behavior and retry rules use error codes instead of parsing error text.

#### PNR-005 — Safe manifest failure handling

- **Status:** done
- **Type:** Architecture
- **Priority:** P0
- **Depends on:** PNR-004
- **Scope:** Do not delete a producer manifest after a generic ping failure. Remove it only for a dead process, a typed stale-session result, or an expired producer-owned lease.
- **Reason:** A temporary timeout must not make a valid live session undiscoverable.
- **Acceptance:** Transient network errors preserve the manifest. Proven stale entries are still removed.

### Milestone 2 — Recoverable review workspace

This milestone implements the selected product priorities in order.

#### PNR-006 — Project-scoped draft persistence

- **Status:** done
- **Type:** Product and architecture
- **Priority:** P0
- **Depends on:** PNR-001, PNR-002, PNR-003
- **Scope:** Persist pending comments, stable IDs, target metadata, and any in-flight snapshot in an atomic, versioned project-scoped store. Restore them after Neovim restart or failure.
- **Reason:** Memory-only comments are the largest trust and data-loss risk.
- **Acceptance:** At least 95% of defined restart and crash recovery scenarios restore the exact pending review. Tokens are never stored. Corrupt data fails safely and remains recoverable where possible.

#### PNR-007 — Same-project draft rebinding

- **Status:** done
- **Type:** Product and architecture
- **Priority:** P0
- **Depends on:** PNR-004, PNR-005, PNR-006
- **Scope:** Keep the original session ID as draft metadata, but allow an explicit authenticated rebind to another live session with the same canonical project root.
- **Reason:** A dead Pi session must not trap a valid draft or force the user to clear it.
- **Acceptance:** Users can recover from a Pi restart without losing comments. Cross-root rebinding is rejected.

#### PNR-008 — `:PiComments` review overview

- **Status:** done
- **Type:** Product
- **Priority:** P0
- **Depends on:** PNR-006
- **Scope:** Add an overview with target, health, comment count, paths, ranges, full text, and actions to jump, edit, delete, preview, and submit.
- **Reason:** Users need to inspect and correct a batch before sending it.
- **Acceptance:** A user can edit and submit one comment from a three-comment review without help. Deleting one item does not affect the others.

#### PNR-009 — Safe clear and submit safeguards

- **Status:** done
- **Type:** Product
- **Priority:** P0
- **Depends on:** PNR-008
- **Scope:** Confirm destructive clear operations. Add exact submission preview and warnings for modified-buffer excerpts or changed source context.
- **Reason:** The current all-or-nothing clear and hidden unsaved-buffer risk reduce confidence.
- **Acceptance:** Clear requires an explicit confirmation when comments exist. Preview shows the actual target and snapshot. Modified-buffer risk is visible before submit.

#### PNR-010 — Sole-session auto-selection and guided connection

- **Status:** done
- **Type:** Product
- **Priority:** P1
- **Depends on:** PNR-004, PNR-005
- **Scope:** Select the session automatically when exactly one healthy session matches the canonical project root. For zero sessions, show specific actions for missing `/nvim`, root mismatch, registry setup, or stale state.
- **Reason:** Manual selection adds no value when there is one valid choice, and generic zero-session errors slow first use.
- **Acceptance:** One valid session requires no picker. Error messages identify a concrete next action. The target remains visible before submission.

### Milestone 3 — Protocol and security hardening

#### PNR-011 — Prompt, request, and connection bounds

- **Type:** Architecture
- **Priority:** P1
- **Depends on:** PNR-004
- **Scope:** Bound `.pi/nvim-review-prompt.md`, the final formatted prompt, aggregate request bytes, and concurrent bridge connections. Define regular-file and symlink policy.
- **Reason:** Local unauthenticated clients can consume sockets before authentication, and project prompt loading is currently unbounded.
- **Acceptance:** Every relevant resource has a documented bound and a typed failure.

#### PNR-012 — Shared wire limits and Lua request checks

- **Type:** Architecture
- **Priority:** P1
- **Depends on:** PNR-004
- **Scope:** Add `lua/pi_nvim/protocol.lua` for request construction and mirrored constants. Enforce annotation count, field size, and aggregate byte limits before transport. Define byte-versus-character semantics.
- **Reason:** The server allows at most 200 annotations, but Lua does not enforce all limits before building a request.
- **Acceptance:** Invalid oversized requests fail locally with the same effective rules as the server.

#### PNR-013 — Registry trust hardening

- **Type:** Architecture
- **Priority:** P1
- **Depends on:** PNR-005
- **Scope:** Check custom registry ownership and permissions, reject or warn about unsafe shared directories, and avoid following manifest symlinks where the platform permits it. Document Windows fallback behavior.
- **Reason:** A hostile manifest can direct source and comments to a fake loopback service.
- **Acceptance:** Unsafe registry locations and manifests cannot be used silently.

#### PNR-014 — Server-side path and content defense

- **Type:** Architecture
- **Priority:** P1
- **Depends on:** PNR-004
- **Scope:** Resolve submitted paths below the canonical root, require root containment and the documented existing-file policy, and treat source excerpts and comments as untrusted prompt data.
- **Reason:** Strict parsing is useful, but file containment and prompt boundaries need independent server-side checks.
- **Acceptance:** Traversal, outside-root, missing-file, and malformed-content cases have explicit policy and typed results.

#### PNR-015 — Versioned protocol contract and capabilities

- **Type:** Architecture
- **Priority:** P1
- **Depends on:** PNR-004, PNR-012
- **Scope:** Define a language-neutral protocol contract. Version manifests, requests, and capabilities independently. Support the current and next version during migration.
- **Reason:** TypeScript and Lua currently duplicate protocol literals without a checked shared contract.
- **Acceptance:** A client can detect compatibility before submit, and one migration window supports adjacent versions.

#### PNR-016 — Redacted diagnostics and status

- **Type:** Product and architecture
- **Priority:** P1
- **Depends on:** PNR-003, PNR-004
- **Scope:** Expose lifecycle state, active session, pending count, submission ID, last ping and submit times, queue result, and last typed error through Neovim and Pi status surfaces.
- **Reason:** Important state exists but is not visible enough to users or maintainers.
- **Acceptance:** A user can diagnose common connection and submission failures without viewing tokens, comments, or source text in logs.

### Milestone 4 — Maintainability and configuration

#### PNR-017 — Focused TypeScript services

- **Type:** Architecture
- **Priority:** P2
- **Depends on:** PNR-001 through PNR-005
- **Scope:** Extract bounded prompt loading and formatting into a pure module. Add a submission service for identity, deduplication, serialization, and delivery. Keep `ReviewBridge` focused on framing, authentication, and connection lifecycle.
- **Reason:** Correct boundaries will be clearer after correctness behavior is defined.
- **Acceptance:** Bridge transport can change without changing prompt formatting or delivery policy.

#### PNR-018 — Focused Lua controller and session state

- **Type:** Architecture
- **Priority:** P2
- **Depends on:** PNR-003, PNR-008, PNR-012
- **Scope:** Keep `init.lua` as the workflow controller, but move protocol construction and explicit session transitions into focused modules. Avoid a framework or broad rewrite.
- **Reason:** The controller should coordinate UI, annotations, persistence, and transport rather than own all details.
- **Acceptance:** Protocol rules and state transitions have one owner each.

#### PNR-019 — Type checking and compatibility policy

- **Type:** Architecture
- **Priority:** P2
- **Depends on:** PNR-015
- **Scope:** Add TypeScript configuration, protocol and transport contract validation, a supported Pi API range instead of an unqualified wildcard policy, and a Node/Neovim/Pi compatibility matrix.
- **Reason:** The package has no scripts, TypeScript project configuration, compatibility matrix, or automated contract checks.
- **Acceptance:** Supported versions and protocol compatibility are explicit and can be validated before release.

#### PNR-020 — Complete Neovim command and mapping configuration

- **Type:** Product
- **Priority:** P1
- **Depends on:** PNR-008, PNR-016
- **Scope:** Add commands and `<Plug>` targets for comments overview, clear, and status. Make modal size and save/cancel mappings configurable. Document sign and highlight options.
- **Reason:** Every action should fit established Neovim configuration patterns.
- **Acceptance:** Every public action is available through a command and a `<Plug>` target without forcing default mappings.

#### PNR-021 — Quick Start and product positioning

- **Type:** Product
- **Priority:** P1
- **Depends on:** PNR-010, PNR-016
- **Scope:** Put a 60-second Quick Start and a concise “why not use a normal Pi prompt?” example before deep protocol details. Lead with precise, local, retry-safe review delivery.
- **Reason:** The current documentation explains implementation before it resolves activation and value questions.
- **Acceptance:** In a five-user check, median install-to-first-submit is below three minutes and at least 80% succeed on the first attempt.

### Milestone 5 — Broader review workflows

#### PNR-022 — File-level and review-level comments

- **Type:** Product
- **Priority:** P2
- **Depends on:** PNR-008, PNR-015
- **Scope:** Support comments that apply to a whole file or the complete review. Optionally add intent shortcuts such as change, explain, and clarify while retaining free text.
- **Reason:** Some useful requests do not belong to one line range.
- **Acceptance:** Non-line comments are represented explicitly in preview and protocol data.

#### PNR-023 — Named review batches

- **Type:** Product
- **Priority:** P2
- **Depends on:** PNR-006, PNR-008
- **Scope:** Let users name a draft and show its exact target, paths, ranges, comments, and buffer state.
- **Reason:** Large multi-file reviews need stronger identity and confidence before submission.
- **Acceptance:** Restored and active batches retain their name and cannot be confused across projects.

#### PNR-024 — Diagnostic, quickfix, and Git diff intake

- **Type:** Product
- **Priority:** P2
- **Depends on:** PNR-008, PNR-022
- **Scope:** Create or triage comments from diagnostics, quickfix items, and Git diff hunks.
- **Reason:** These sources can turn the plugin into a more complete review workbench.
- **Acceptance:** Each source creates normal review records that users can inspect and edit before submit.

### Milestone 6 — Detached bridge option

#### PNR-025 — Durable detached Pi RPC helper

- **Status:** planned
- **Type:** Product and architecture
- **Priority:** P2
- **Depends on:** PNR-001 through PNR-019
- **Scope:** Evaluate and, if justified, implement a detached helper that survives Pi reload or restart. Define secure endpoint ownership, leases, token rotation, durable submission IDs and results, and a clear helper-to-Pi acknowledgement contract.
- **Reason:** The live Pi process and repeated `/nvim` requirement are important product restrictions, but removing them before delivery semantics are sound would increase risk.
- **Acceptance:** Restart and reload do not lose accepted results or create duplicate delivery. The helper does not persist reusable session tokens.
- **Investigation outcome:** A helper is justified as a durable inbox and delivery coordinator, not as a detached `pi --mode rpc` owner. An RPC child would create a separate headless Pi session, and its successful `prompt` response confirms preflight acceptance rather than durable message persistence.
- **Recommended contract:** The helper atomically stores the submission ID, payload fingerprint, exact formatted prompt, target session ID, and delivery state before acknowledgement. A session-scoped Pi extension lease then pulls deliveries. It acknowledges one only after a user message containing the stable submission marker is visible in the Pi session journal. On reconnect, the extension scans that journal before redelivery, which closes the crash window between Pi persistence and helper acknowledgement.
- **Security and lifecycle:** Use one user-owned endpoint, short renewable leases, a new random token for each lease, token digests rather than reusable tokens in durable state, restrictive files, atomic state transitions, and idle helper shutdown. A disconnected but unexpired lease can accept durable work with an explicit `stored` result; an expired lease rejects new work.
- **Implementation gate:** Complete PNR-011 through PNR-019 first. Before full implementation, prove the helper contract with a small crash-recovery spike covering failure before helper persistence, after helper persistence, after Pi message persistence, and after helper delivery acknowledgement.

## Initial implementation sequence

Start in this order:

1. `PNR-001` — duplicate-safe submission identity.
2. `PNR-002` — serialized delivery and stable snapshots.
3. `PNR-003` — explicit lifecycle and safe shutdown.
4. `PNR-004` — typed protocol results.
5. `PNR-005` — safe manifest handling.
6. `PNR-006` — review-loss prevention through persistence.
7. `PNR-007` — safe same-project rebinding.
8. `PNR-008` — `:PiComments` overview.
9. `PNR-009` — preview, modified-buffer warning, and safe clear.
10. `PNR-010` — automatic selection of one valid session.

After this sequence, complete the hardening, maintainability, configuration, and broader workflow milestones in dependency order.

## Success measures

- At least 95% of defined restart and crash scenarios restore the exact review draft.
- Retry after a lost acknowledgement does not create a duplicate Pi message.
- A Pi restart does not require users to discard a same-project draft.
- At least 90% of test users can edit and submit one comment from a three-comment review without help.
- A single valid session is selected without opening the picker.
- Median install-to-first-submit time is below three minutes in a five-user check.
- No token, comment, or source excerpt appears in diagnostic logs.
- The first post-roadmap release has no confirmed draft-loss reports during its observation period.

## Risks and open questions

- The exact delivery guarantee of `pi.sendUserMessage()` must be confirmed. The plan assumes delivery can succeed before Neovim receives an acknowledgement.
- In-memory bridge deduplication cannot prevent duplicates after bridge restart. Durable deduplication belongs to `PNR-025` or another durable owner.
- Persistence location and cleanup rules must work on supported operating systems and must not expose review text through unsafe permissions.
- Ownership and no-follow file APIs differ on Unix and Windows.
- `<C-s>` behavior differs across terminals and user mappings.
- No user research, analytics, issue history, or adoption data is currently available. Product priorities use workflow severity rather than measured demand.

## Evidence from the planning baseline

- `README.md` documents the dual installation, structured review workflow, retry behavior, memory-only comments, exact-root requirement, pending-comment session lock, and live-process restriction.
- `lua/pi_nvim/init.lua` blocks session selection while comments exist, removes manifests after broad ping failures, and clears exact record IDs only after acknowledgement.
- `lua/pi_nvim/annotations.lua` keeps records in memory and builds sorted submission snapshots.
- `plugin/pi_nvim.lua` registers select, annotate, submit, and clear commands, with `<Plug>` mappings only for annotate and submit.
- `lua/pi_nvim/modal.lua` uses fixed default dimensions and fixed save bindings.
- `extensions/nvim-review/bridge.ts` owns sockets and prompt loading but does not track request-handler completion during shutdown.
- `extensions/nvim-review/index.ts` sends the Pi message before the bridge returns the TCP acknowledgement.
- `extensions/nvim-review/protocol.ts` validates bounded requests but has no submission identity or typed error code.
- `extensions/nvim-review/registry.ts` creates restrictive atomic manifests, while the Lua reader needs stronger trust checks for custom registry locations.
- `package.json` uses a wildcard Pi peer dependency and has no TypeScript scripts, compatibility matrix, or contract-check configuration.

## Planning source

This plan consolidates two read-only Herdr reviews:

- a product management review of user value, workflow friction, adoption, and roadmap;
- a software architecture review of state, delivery, protocol, lifecycle, security, and maintainability.

The Herdr agents used `openai-codex/gpt-5.6-sol:high`. They did not modify the checkout or run tests.
