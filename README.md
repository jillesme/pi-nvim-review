# pi-nvim-review

`pi-nvim-review` connects Neovim to a live [Pi](https://pi.dev) session. Mark lines in Neovim, write review comments, and submit the full review to Pi as one user message.

The repository is both:

- a Pi package with a TypeScript extension;
- a Neovim plugin with no Lua plugin dependency.

## Requirements

- Pi with extension package support
- Node.js 20 or newer for the Pi extension
- Neovim 0.10 or newer

## Installation

Install both parts from the same checkout or Git source: the extension in Pi and the plugin in Neovim.

### Local checkout

Clone or download the repository, then install its Pi package:

```sh
cd /absolute/path/to/pi-nvim-review
pi install "$PWD"
```

Add the checkout to Neovim. With lazy.nvim:

```lua
{
  dir = "/absolute/path/to/pi-nvim-review",
}
```

Without a plugin manager, link the checkout into Neovim's native package directory:

```sh
mkdir -p ~/.local/share/nvim/site/pack/pi/start
ln -s /absolute/path/to/pi-nvim-review \
  ~/.local/share/nvim/site/pack/pi/start/pi-nvim-review
```

Restart Pi and Neovim after installation. Run `/nvim` in Pi to confirm that the extension loaded. In Neovim, run `:help pi-nvim` to confirm that the plugin loaded.

For a one-time Pi run during development, load the extension directly instead of installing it:

```sh
pi -e /absolute/path/to/pi-nvim-review/extensions/nvim-review/index.ts
```

### Git source

Install the public Git repository in Pi and Neovim:

```sh
pi install git:github.com/jillesme/pi-nvim-review
```

```lua
{
  "jillesme/pi-nvim-review",
}
```

Pi packages run with full system access. Review the source before you install a third-party package.

## Code tours

The `.tours` directory contains guided walkthroughs of the transport path and protocol data structures. They are optional and are not required to use the plugin.

To view them in the terminal, install [Tourminal](https://github.com/jillesme/tourminal):

```sh
brew install jillesme/tap/tourminal
```

From the repository root, run `tour` to select a walkthrough, or open one directly:

```sh
tour --tour .tours/neovim-to-pi-transport.tour
tour --tour .tours/review-data-structures.tour
```

The files also work with the Microsoft CodeTour extension for VS Code.

## Workflow

1. Start Pi in the project root.
2. Run `/nvim` in Pi.

   Pi starts a local bridge and reports a short ID:

   ```text
   Neovim session started (abc13)
   ```

3. Keep that Pi process open. Open Neovim with the same project root as its current working directory.
4. Run `:Pi`, move through the modal session picker, and press `<Enter>` on `abc13`.
5. Add comments:
   - normal mode `<leader>pa` opens a multiline comment modal for the current line;
   - visual mode `<leader>pa` opens it for the selected line range;
   - press `<C-s>` to save the comment or `<Esc>` to cancel it.
6. Run `<leader>ps` or `:PiSubmit`.

Pi receives one user message with sorted project-relative paths, current line ranges, source excerpts, and comments. If Pi is idle, processing starts immediately. If Pi is busy, the review is queued as a follow-up and does not interrupt the current task.

After Pi accepts the message, Neovim removes the submitted signs and comments. The selected session stays active, so you can start another review cycle.

## Commands

| Command | Action |
| --- | --- |
| `:Pi` | List live sessions for Neovim's canonical current working directory and select one. |
| `:[range]PiAnnotate` | Add a comment to the current line or supplied line range. |
| `:PiSubmit` | Submit all pending comments to the active session. |
| `:PiClear` | Remove all pending comments without submitting them. |

Neovim requires user commands to start with an uppercase letter. This is why the commands use `:Pi` and `:PiSubmit`, not lowercase or hyphenated names.

## Modal controls

`:Pi` opens a centered session picker. Use `j`/`k` or `<C-n>`/`<C-p>` to move, `<Enter>` to select, and `<Esc>` or `q` to cancel.

`:PiAnnotate` opens a bordered multiline editor below the selected or current line when there is enough room. It uses a centered file-window fallback near the bottom of the screen. Press `<C-s>` in normal or insert mode to add the comment. Press `<Esc>`, `<C-c>`, or normal-mode `q` to cancel it.

## Mappings

The plugin defines these `<Plug>` targets:

- `<Plug>(PiAnnotate)` in normal and visual modes
- `<Plug>(PiSubmit)` in normal mode

It adds the following defaults only when the left-hand side is free and no mapping already targets the matching `<Plug>` mapping:

| Mode | Default | Action |
| --- | --- | --- |
| Normal | `<leader>pa` | Annotate current line |
| Visual | `<leader>pa` | Annotate selected lines |
| Normal | `<leader>ps` | Submit comments |

To define your own mappings, disable defaults before the plugin loads:

```lua
vim.g.pi_nvim_disable_default_mappings = true

vim.keymap.set({ "n", "x" }, "<leader>pc", "<Plug>(PiAnnotate)")
vim.keymap.set("n", "<leader>pr", "<Plug>(PiSubmit)")
```

With lazy.nvim, put the global option in `init`:

```lua
{
  dir = "/absolute/path/to/pi-nvim-review",
  init = function()
    vim.g.pi_nvim_disable_default_mappings = true
  end,
}
```

## Configuration

Defaults work without calling `setup()`.

```lua
require("pi_nvim").setup({
  timeout_ms = 3000,
  registry_dir = nil,
})
```

- `timeout_ms` controls ping and submission timeouts.
- `registry_dir` changes where Neovim reads live-session manifests. The Pi process must use the same directory.

The simplest shared registry override is an environment variable set for both Pi and Neovim:

```sh
export PI_NVIM_REGISTRY="$HOME/.cache/pi-nvim-sessions"
```

By default, both plugins use a user-specific directory below the operating system temporary directory.

### Review prompt

To replace the default review instructions for one project, create `.pi/nvim-review-prompt.md` in the project root. For example:

```md
Apply the review comments below. Preserve backward compatibility.
Run the relevant checks after making changes.
Report each change and any comment that you could not apply.
```

The bridge reads this file for each submission. Its contents replace the standard opening instructions. The project root and the structured review comments, including file paths, line ranges, comments, and source excerpts, are always appended. An empty file omits the opening instructions. If the file does not exist, the bridge uses the default instructions.

If the file exists but cannot be read, submission fails and Neovim keeps the pending comments so that you can fix the file and retry.

## MVP restrictions

- **The Pi process must stay open.** The bridge belongs to the Pi process that handled `/nvim`. Pi exit, session replacement, or `/reload` closes it. A future version can move ownership to a detached Pi RPC process.
- **Comments are in memory only.** Exiting Neovim loses comments that were not submitted.
- **The project root must match.** `:Pi` compares Pi's canonical startup directory with Neovim's canonical `getcwd()`. Use `:cd` to enter the Pi project root before `:Pi`.
- **Pending comments lock session selection.** While comments are pending, `:Pi` will not change sessions. Use `:PiSubmit` or `:PiClear` first. This prevents comments from going to the wrong Pi session.
- **Only existing project files are accepted.** Unnamed buffers, special buffers, missing files, and files that resolve outside the selected project root cannot be annotated.
- Source excerpts can contain unsaved Neovim buffer text. Save related edits before Pi changes the same files to avoid normal editor/disk conflicts.

## Failure behavior

A submission clears comments only after the selected Pi bridge validates and accepts it. Invalid payloads, timeouts, dead sessions, and delivery errors keep all comments for retry.

A Pi crash can leave a stale temporary manifest. `:Pi` filters dead process IDs and removes a selected manifest when its authenticated ping fails.

## Local protocol

`/nvim` binds an ephemeral TCP port on `127.0.0.1`. Its discovery manifest and random access token use user-only filesystem permissions. The versioned JSON-line protocol validates the token, session identity, project root, relative paths, annotation fields, and bounded payload sizes. The server accepts one request per connection.

Use `:help pi-nvim` for the Neovim reference.
