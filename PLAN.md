# Neovim + Pi review bridge

## Context

Create a new package in this empty repository with two parts:

- a Pi TypeScript extension that starts a review bridge with `/nvim` for the current Pi session;
- a Neovim Lua plugin that discovers bridge sessions, lets the user attach comments to source lines, and submits those comments to the selected Pi session.

Target workflow: start the bridge in Pi, select it in Neovim, annotate files, submit the annotations as one Pi user message, then reuse the same bridge after the annotations are cleared.

## Approach

- Keep the original Pi process open as the owner of the live session. `/nvim` starts one idempotent bridge for that session and reports a five-character display ID such as `abc13`. Add an explicit TODO and README limitation for a future detached bridge that survives Pi exit.
- Bind a Node TCP server to an ephemeral `127.0.0.1` port. Publish a versioned manifest in a per-user temporary registry directory (`PI_NVIM_REGISTRY` can override it). The manifest contains the canonical Pi working directory, full and short session IDs, process ID, port, start time, optional session name, and a random access token. Create the directory and file with user-only permissions and replace the manifest atomically.
- Let `:Pi` scan manifests and show only sessions whose canonical project root equals Neovim's current working directory. Filter dead process IDs, verify the selected session with a `ping`, and remove stale manifests after failed verification.
- Use newline-delimited JSON for one request per local TCP connection. Validate the protocol version, token, session ID, project root, relative paths, field types, annotation count, and payload size before accepting a submission.
- Implement the Neovim UI only with built-in APIs: floating modal windows for session selection and multiline comments, user commands, and extmarks for line/range tracking plus `Pi` sign/virtual text. Require Neovim 0.10 or newer and use `vim.uv` for registry and TCP work.
- Provide `<Plug>` mappings and install the approved defaults only when their left-hand sides are not already mapped: normal/visual `<leader>pa` for `:PiAnnotate`, and normal `<leader>ps` for `:PiSubmit`. Allow users to disable or replace defaults.
- Keep annotations in Neovim memory for the MVP. Bind each batch to its selected live session, reject files outside that session's root, resolve current extmark positions at submit time, and include current source lines (including unsaved buffer text) in a deterministic project-relative payload. While a batch is pending, block `:Pi` from changing sessions until the user submits it or runs `:PiClear`; document this MVP restriction.
- Format one readable user prompt that asks Pi to apply all review comments, with each filename, current line range, numbered source excerpt, and comment. Send immediately when Pi is idle. If Pi is busy, send it with `deliverAs: "followUp"` so it is queued without interrupting the current task.
- Return an acceptance response only after `pi.sendUserMessage` succeeds. Neovim clears extmarks and in-memory annotations only after this response; transport or validation failures retain them for retry.
- Close the server, clear the Pi footer status, and remove the manifest on `session_shutdown`. A crash can leave a manifest, so Neovim must handle stale entries safely.

## Files to modify

The repository is empty. Use one repository root that is both an installable Pi package and a standard Neovim runtime, so the same Git source can be installed by Pi and a Neovim plugin manager.

- `package.json` — `pi-nvim-review` metadata, `pi-package` keyword, Pi extension manifest, package file list, and Pi peer dependency; no third-party runtime dependency
- `extensions/nvim-review/index.ts` — Pi extension entry point, `/nvim` command, session events, and footer status
- `extensions/nvim-review/bridge.ts` — loopback server, request framing/validation, prompt delivery, responses, and cleanup
- `extensions/nvim-review/registry.ts` — shared registry path rules and atomic manifest lifecycle
- `extensions/nvim-review/protocol.ts` — manifest/request/response types, limits, and validators
- `plugin/pi_nvim.lua` — guarded, minimal command and `<Plug>`/default mapping registration with deferred `require`
- `lua/pi_nvim/init.lua` — public Neovim actions and active-session state
- `lua/pi_nvim/registry.lua` — project-scoped manifest discovery and stale-entry handling
- `lua/pi_nvim/client.lua` — asynchronous `vim.uv` TCP client, JSON framing, timeout, and cleanup
- `lua/pi_nvim/modal.lua` — centered session picker and multiline comment editor positioned below the annotated line with a centered fallback
- `lua/pi_nvim/annotations.lua` — in-memory line/range records, extmarks, source extraction, and clear behavior
- `doc/pi-nvim.txt` and generated `doc/tags` — concise `:help pi-nvim` commands, mappings, configuration, and limitations
- `README.md` — Pi and Neovim installation, complete workflow, configuration, protocol limitations, and future detached-session note

## Reuse

- Pi `pi.registerCommand()` for `/nvim`; `ctx.sessionManager.getSessionId()` and `getSessionFile()` for identity; `pi.getSessionName()` for selector metadata; `ctx.isIdle()` and `pi.sendUserMessage()` for immediate delivery; `session_info_changed` to refresh the manifest; and `session_shutdown` for resource cleanup (`docs/extensions.md`, `docs/session-format.md`).
- Pi package discovery through the `package.json#pi.extensions` manifest and `@earendil-works/pi-coding-agent` as a `"*"` peer dependency (`docs/packages.md`).
- Node built-ins `node:net`, `node:crypto`, `node:fs/promises`, `node:os`, and `node:path`; no custom networking or filesystem dependency.
- Neovim's documented plugin conventions: a small guarded `plugin/` entry point, deferred Lua module loading, `<Plug>` mappings, and conflict-aware defaults (`lua-plugin.txt`).
- Neovim built-ins `vim.api.nvim_open_win`, `vim.api.nvim_create_user_command`, `vim.api.nvim_buf_set_extmark`/`nvim_buf_get_extmark_by_id`, `vim.json`, and `vim.uv` TCP/filesystem/timer APIs.
- No existing project code is available; the directory is empty.

## Steps

- [x] Scaffold the combined Pi package/Neovim runtime, declare the Pi peer dependency, and add the extension manifest without third-party runtime packages.
- [x] Define protocol version 1 and strict manifest, `ping`, `submit`, success, and error shapes with bounded request/comment/source sizes.
- [x] Implement atomic, user-only registry metadata using the same temporary-directory/user-ID algorithm in TypeScript and Lua, with `PI_NVIM_REGISTRY` as an escape hatch.
- [x] Implement idempotent `/nvim`: canonicalize `ctx.cwd`, start a loopback server on an ephemeral port, write the manifest, show `Neovim session started (abc13)`, and set a Pi footer status.
- [x] Validate one JSON-line request per connection, answer `ping`, convert accepted annotations into a deterministic review prompt, and call `pi.sendUserMessage` immediately when idle or with `deliverAs: "followUp"` when busy; keep a TODO for detached Pi/RPC ownership.
- [x] Refresh optional session-name metadata after `session_info_changed`; close sockets/status and delete the manifest idempotently on every `session_shutdown` reason.
- [x] Register `:Pi`, `:PiAnnotate`, `:PiSubmit`, and `:PiClear`, plus `<Plug>` targets and conflict-aware `<leader>pa`/`<leader>ps` defaults in the lazy Neovim entry point.
- [x] Discover only manifests for canonical `getcwd()`, filter dead PIDs, verify the selected item with `ping`, and record it as the active session; block session changes while annotations are pending with guidance to submit or clear first.
- [x] Add normal-line and visual-line-range comments through a multiline floating modal; disallow unnamed/special/out-of-root buffers; track ranges with extmarks and show a plain `Pi` sign plus concise virtual text.
- [x] Resolve current extmark ranges and source lines at submit time, sort by relative path/range/insertion order, send asynchronously with a timeout, and keep annotations on every failure.
- [x] On acceptance, clear all submitted extmarks/records, report whether Pi accepted or queued the prompt, and permit the next annotation/submission cycle against the same active session.
- [x] Document installation through `pi install`/`pi -e` and a Neovim plugin manager, all commands/mappings/configuration, in-memory-only comments, same-root matching, blocked session changes with pending comments, Pi-process lifetime, busy follow-up delivery, and stale-session recovery in README and vimdoc.

## Verification

- Run `npm pack --dry-run` and inspect the package contents; load the extension from the local repository with Pi and check that the documented peer import resolves without a bundled runtime dependency.
- Start `/nvim` twice in one persisted Pi session; confirm both calls report the same short ID, only one loopback listener/manifest exists, the manifest is user-only, and Pi shows the active status.
- Start two Pi sessions in one project and one in another. Open Neovim at each canonical root, run `:Pi`, and confirm only same-root live sessions appear with their short IDs/names.
- Use normal `<leader>pa` and visual `<leader>pa` in multiple named files. Confirm the plain sign/virtual text appears, ranges follow insertions/deletions through extmarks, and files outside the active project are rejected.
- Use `<leader>ps`/`:PiSubmit` while Pi is idle and busy; inspect the Pi transcript and confirm one immediate or queued follow-up turn contains sorted project-relative filenames, current 1-based ranges, source text, and multiline comments without interrupting busy work.
- Force invalid token, malformed JSON, oversized payload, dead port, and delivery failure cases. Confirm the bridge returns bounded errors, Neovim does not block, and pending comments remain.
- Confirm `:Pi` refuses to change sessions while comments are pending and explains `:PiSubmit`/`:PiClear`. Confirm a successful response clears only the submitted records, the same bridge accepts a second cycle, and `:PiClear` manually removes pending marks.
- Exit, reload, or replace the Pi session. Confirm server handles close, status clears, the live manifest is removed, and a simulated crash manifest is ignored/removed by Neovim after verification fails.
- Run Neovim headless with the repository on `runtimepath` to confirm plugin startup and command registration have no errors; manually run the picker/input/extmark workflow in Neovim 0.10+.
