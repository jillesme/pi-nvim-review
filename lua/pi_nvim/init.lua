local annotations = require("pi_nvim.annotations")
local client = require("pi_nvim.client")
local draft = require("pi_nvim.draft")
local modal = require("pi_nvim.modal")
local registry = require("pi_nvim.registry")

local M = {}

local config = {
  timeout_ms = 3000,
  registry_dir = nil,
}

local active_session
local client_state = "disconnected"
local draft_root
local draft_target
local pending_submission
local persist_scheduled = false
local restored_roots = {}

local function notify(message, level)
  vim.notify("pi-nvim: " .. message, level or vim.log.levels.INFO)
end

local function current_root()
  return registry.canonical(vim.uv.cwd() or vim.fn.getcwd())
end

local function request_for(session, request_type)
  return {
    protocolVersion = 2,
    type = request_type,
    token = session.token,
    sessionId = session.sessionId,
    projectRoot = session.projectRoot,
  }
end

local function display_name(session)
  if not session then
    return "none"
  end
  local name = session.sessionName
  if type(name) == "string" and name ~= "" then
    name = name:gsub("[%c]", " ")
    return string.format("%s (%s)", name, session.shortId)
  end
  return string.format("%s (pid %d)", session.shortId, session.pid)
end

local function stored_target(session)
  if not session then
    return nil
  end
  return {
    sessionId = session.sessionId,
    shortId = session.shortId,
    projectRoot = session.projectRoot,
    pid = session.pid,
    startedAt = session.startedAt,
    sessionName = session.sessionName,
  }
end

local function relative_path(root, path)
  if root == path then
    return nil
  end

  local separator = root:find("\\", 1, true) and "\\" or "/"
  local prefix = root
  if prefix:sub(-1) ~= separator then
    prefix = prefix .. separator
  end

  local compare_root = prefix
  local compare_path = path
  if package.config:sub(1, 1) == "\\" then
    compare_root = compare_root:lower()
    compare_path = compare_path:lower()
  end

  if compare_path:sub(1, #compare_root) ~= compare_root then
    return nil
  end
  return path:sub(#prefix + 1):gsub("\\", "/")
end

local function persist_workspace(report_error)
  if not draft_root then
    return true
  end
  local ok, error_message = draft.save(draft_root, draft_target, annotations.serialize(), pending_submission)
  if not ok and report_error ~= false then
    notify(error_message or "could not save the review draft", vim.log.levels.ERROR)
  end
  return ok ~= nil
end

local function schedule_persist()
  if persist_scheduled or not draft_root then
    return
  end
  persist_scheduled = true
  vim.defer_fn(function()
    persist_scheduled = false
    persist_workspace(false)
  end, 100)
end

local function switch_workspace(root)
  if draft_root == root then
    return true
  end
  if client_state == "submitting" or client_state == "connecting" then
    notify("wait for the current Pi request before changing projects", vim.log.levels.WARN)
    return false
  end

  if draft_root and (annotations.count() > 0 or pending_submission) and not persist_workspace(false) then
    notify("could not save the current review; the project was not changed", vim.log.levels.ERROR)
    return false
  end
  annotations.reset()
  active_session = nil
  client_state = "disconnected"
  draft_root = root
  draft_target = nil
  pending_submission = nil

  local data, load_error = draft.load(root)
  if load_error then
    notify(load_error, vim.log.levels.ERROR)
    return true
  end
  if data then
    annotations.restore(root, data.comments)
    draft_target = data.target
    pending_submission = data.submission
    if #data.comments > 0 and not restored_roots[root] then
      restored_roots[root] = true
      notify(string.format(
        "restored %d pending comment%s; select a live session to authenticate",
        #data.comments,
        #data.comments == 1 and "" or "s"
      ))
    end
  end
  return true
end

local function ensure_workspace()
  return switch_workspace(current_root())
end

local function snapshot_contains(id)
  if not pending_submission then
    return false
  end
  for _, snapshot_id in ipairs(pending_submission.ids) do
    if snapshot_id == id then
      return true
    end
  end
  return false
end

local function set_connection_error(err, session)
  local failed_active = active_session and active_session.sessionId == session.sessionId
  if err.code == "stale_session" then
    registry.remove(session)
    if failed_active then
      active_session = nil
    end
    client_state = active_session and "ready" or "stale"
  elseif err.code == "authentication_failed" or err.code == "incompatible_version" or err.code == "bridge_stopping" then
    if failed_active then
      active_session = nil
    end
    client_state = active_session and "ready" or "stale"
  elseif active_session then
    client_state = "ready"
  else
    client_state = "disconnected"
  end
end

local function activate_session(choice)
  active_session = choice
  client_state = "ready"
  draft_target = stored_target(choice)
  persist_workspace()
  notify("active Pi session is " .. display_name(choice))
end

local function confirm_rebind(choice)
  local old_target = pending_submission and pending_submission.sessionId
    or (draft_target and draft_target.sessionId)
  if annotations.count() == 0 or not old_target or old_target == choice.sessionId then
    activate_session(choice)
    return
  end

  vim.ui.select({ "Rebind draft", "Keep original target" }, {
    prompt = string.format("Move this pending review to authenticated session %s?", choice.shortId),
  }, function(selection)
    if selection ~= "Rebind draft" then
      client_state = active_session and "ready" or "disconnected"
      notify("kept the original draft target", vim.log.levels.INFO)
      return
    end

    -- A snapshot ID belongs to the bridge that may already have accepted it.
    -- Persist cancellation before rebinding so a restart cannot retry that ID.
    local target = stored_target(choice)
    local saved, save_error = draft.save(draft_root, target, annotations.serialize(), nil)
    if not saved then
      client_state = active_session and "ready" or "disconnected"
      notify(save_error or "could not save the rebound draft", vim.log.levels.ERROR)
      return
    end
    pending_submission = nil
    activate_session(choice)
  end)
end

local function connect_session(choice)
  client_state = "connecting"
  client.request(choice, request_for(choice, "ping"), config.timeout_ms, function(err, response)
    if err then
      set_connection_error(err, choice)
      local guidance = ""
      if err.code == "incompatible_version" then
        guidance = "; update the Pi and Neovim plugin installations together"
      elseif err.code == "authentication_failed" then
        guidance = "; run /nvim again in Pi and retry :Pi"
      elseif err.code == "stale_session" then
        guidance = "; run /nvim again in the target Pi session"
      end
      notify(client.message(err) .. guidance, vim.log.levels.ERROR)
      return
    end
    if response.type ~= "pong" or response.sessionId ~= choice.sessionId then
      client_state = "disconnected"
      notify("selected Pi session returned the wrong identity; its manifest was kept", vim.log.levels.ERROR)
      return
    end
    confirm_rebind(choice)
  end)
end

function M.setup(opts)
  opts = opts or {}
  if opts.timeout_ms ~= nil then
    assert(
      type(opts.timeout_ms) == "number" and opts.timeout_ms > 0 and opts.timeout_ms % 1 == 0,
      "timeout_ms must be a positive integer"
    )
    config.timeout_ms = opts.timeout_ms
  end
  if opts.registry_dir ~= nil then
    assert(type(opts.registry_dir) == "string" and opts.registry_dir ~= "", "registry_dir must be a non-empty string")
    config.registry_dir = opts.registry_dir
  end
  ensure_workspace()
end

function M.select_session()
  if not ensure_workspace() then
    return
  end
  if client_state == "submitting" or client_state == "connecting" then
    notify("wait for the current Pi request before changing sessions", vim.log.levels.WARN)
    return
  end

  local root = draft_root
  local sessions = registry.discover(root, config.registry_dir)
  if #sessions == 0 then
    notify(
      "no live Pi sessions match " .. root .. "; start Pi in this exact root, run /nvim, and check PI_NVIM_REGISTRY",
      vim.log.levels.WARN
    )
    return
  end

  if #sessions == 1 then
    connect_session(sessions[1])
    return
  end

  local _, modal_error = modal.select(sessions, {
    title = "Pi sessions · " .. vim.fn.fnamemodify(root, ":t"),
    format_item = display_name,
  }, function(choice)
    if choice then
      connect_session(choice)
    end
  end)
  if modal_error then
    notify("could not open session picker: " .. modal_error, vim.log.levels.ERROR)
  end
end

function M.annotate(start_line, end_line)
  if not ensure_workspace() then
    return
  end
  if client_state == "submitting" or client_state == "connecting" then
    notify("wait for the current Pi request before adding a comment", vim.log.levels.WARN)
    return
  end
  if not active_session or client_state ~= "ready" then
    notify("select a live session with :Pi first", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then
    notify("comments can only be added to normal file buffers", vim.log.levels.WARN)
    return
  end

  local buffer_name = vim.api.nvim_buf_get_name(bufnr)
  if buffer_name == "" then
    notify("save this buffer to a project file before adding a comment", vim.log.levels.WARN)
    return
  end

  local absolute_path = vim.uv.fs_realpath(buffer_name)
  if not absolute_path then
    notify("save this file before adding a comment", vim.log.levels.WARN)
    return
  end

  local path = relative_path(active_session.projectRoot, absolute_path)
  if not path or path == "" then
    notify("the current file is outside the active Pi project", vim.log.levels.WARN)
    return
  end

  local first_line = math.min(start_line, end_line)
  local last_line = math.max(start_line, end_line)
  start_line = first_line
  end_line = last_line
  if end_line - start_line + 1 > 1000 then
    notify("one comment cannot cover more than 1000 lines", vim.log.levels.WARN)
    return
  end

  local selected_session_id = active_session.sessionId
  local location = start_line == end_line and tostring(start_line) or string.format("%d-%d", start_line, end_line)
  local source_window = vim.api.nvim_get_current_win()
  local _, modal_error = modal.input({
    title = string.format("Pi comment · %s:%s", path, location),
    source_window = source_window,
    target_line = end_line,
  }, function(comment)
    if comment == nil then
      return
    end
    if vim.trim(comment) == "" then
      notify("empty comment was not added", vim.log.levels.WARN)
      return
    end
    if #comment > 16 * 1024 then
      notify("comment is larger than 16 KiB", vim.log.levels.WARN)
      return
    end
    if not active_session or active_session.sessionId ~= selected_session_id then
      notify("active Pi session changed before the comment was added", vim.log.levels.ERROR)
      return
    end

    local id, add_error = annotations.add(bufnr, absolute_path, path, start_line, end_line, comment)
    if add_error then
      notify("could not display comment: " .. add_error, vim.log.levels.ERROR)
      return
    end
    if not persist_workspace() then
      annotations.delete(id)
      notify("the comment was not added because the draft could not be saved", vim.log.levels.ERROR)
      return
    end
    notify("comment added at " .. path .. ":" .. location)
  end)
  if modal_error then
    notify("could not open comment editor: " .. modal_error, vim.log.levels.ERROR)
  end
end

local function new_submission_id()
  return vim.fn.sha256(table.concat({
    draft_root,
    tostring(vim.uv.os_getpid()),
    tostring(vim.uv.hrtime()),
    tostring(math.random()),
  }, ":"))
end

local function prepare_submission_snapshot()
  if pending_submission then
    return pending_submission, false
  end

  local payload, ids, build_error, risks = annotations.build()
  if not payload then
    return nil, false, build_error or "could not build review payload"
  end
  pending_submission = {
    submissionId = new_submission_id(),
    sessionId = active_session.sessionId,
    projectRoot = active_session.projectRoot,
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    attempted = false,
    ids = ids,
    annotations = payload,
    risks = risks,
  }
  if not persist_workspace() then
    pending_submission = nil
    return nil, false, "submission was cancelled because its retry snapshot could not be saved"
  end
  return pending_submission, true
end

function M.submit()
  if not ensure_workspace() then
    return
  end
  if client_state == "submitting" then
    notify("a review submission is already in progress", vim.log.levels.WARN)
    return
  end
  if client_state == "connecting" then
    notify("wait for Pi session authentication to finish", vim.log.levels.WARN)
    return
  end
  if not active_session or client_state ~= "ready" then
    notify("select a live session with :Pi first", vim.log.levels.WARN)
    return
  end
  if annotations.count() == 0 then
    notify("there are no comments to submit", vim.log.levels.WARN)
    return
  end

  if pending_submission and pending_submission.sessionId ~= active_session.sessionId then
    notify("the retry snapshot belongs to another Pi session; use :Pi to rebind it explicitly", vim.log.levels.WARN)
    return
  end

  local snapshot, created, prepare_error = prepare_submission_snapshot()
  if not snapshot then
    notify(prepare_error, vim.log.levels.ERROR)
    return
  end
  if created and #snapshot.risks > 0 then
    notify("review the submission warnings before sending", vim.log.levels.WARN)
    M.preview()
    return
  end

  if snapshot.attempted == false then
    snapshot.attempted = true
    if not persist_workspace() then
      snapshot.attempted = false
      notify("submission was cancelled because its attempted state could not be saved", vim.log.levels.ERROR)
      return
    end
  end

  local session = active_session
  local request = request_for(session, "submit")
  request.submissionId = snapshot.submissionId
  request.annotations = snapshot.annotations
  client_state = "submitting"

  client.request(session, request, config.timeout_ms, function(err, response)
    if err then
      set_connection_error(err, session)
      persist_workspace(false)
      local retry_note = err.retryable and "; comments and the stable retry snapshot were kept" or "; comments were kept"
      notify(client.message(err) .. retry_note, vim.log.levels.ERROR)
      return
    end

    client_state = "ready"
    if response.type ~= "submitted"
      or response.sessionId ~= session.sessionId
      or response.submissionId ~= snapshot.submissionId
      or response.count ~= #snapshot.annotations
    then
      notify("Pi returned an invalid submission acknowledgement; comments were kept", vim.log.levels.ERROR)
      return
    end

    local cleared = {}
    for _, id in ipairs(snapshot.ids) do
      cleared[id] = true
    end
    local remaining = {}
    for _, item in ipairs(annotations.serialize()) do
      if not cleared[item.id] then
        remaining[#remaining + 1] = item
      end
    end
    local saved, save_error = draft.save(draft_root, draft_target, remaining, nil)
    if not saved then
      notify(
        (save_error or "could not save the acknowledgement")
          .. "; the retry snapshot was kept and remains duplicate-safe while this bridge is live",
        vim.log.levels.ERROR
      )
      return
    end

    annotations.clear(snapshot.ids)
    pending_submission = nil
    local verb = response.status == "queued" and "queued" or "submitted"
    notify(string.format(
      "%d comment%s %s to Pi session %s",
      #snapshot.annotations,
      #snapshot.annotations == 1 and "" or "s",
      verb,
      session.shortId
    ))
  end)
end

function M.clear()
  if not ensure_workspace() then
    return
  end
  if client_state == "submitting" or client_state == "connecting" then
    notify("wait for the current Pi request before clearing comments", vim.log.levels.WARN)
    return
  end

  local count = annotations.count()
  if count == 0 then
    notify("there are no comments to clear")
    return
  end

  local confirmed_root = draft_root
  local confirmed_comments = annotations.serialize()
  local confirmed_submission_id = pending_submission and pending_submission.submissionId or nil
  local snapshot_note = confirmed_submission_id and " and cancel its retry snapshot" or ""
  vim.ui.select({ "Keep review", "Clear review" }, {
    prompt = string.format(
      "Permanently clear %d pending comment%s%s?",
      count,
      count == 1 and "" or "s",
      snapshot_note
    ),
  }, function(selection)
    if selection ~= "Clear review" then
      return
    end
    if draft_root ~= confirmed_root
      or current_root() ~= confirmed_root
      or client_state == "submitting"
      or client_state == "connecting"
      or not vim.deep_equal(annotations.serialize(), confirmed_comments)
      or (pending_submission and pending_submission.submissionId or nil) ~= confirmed_submission_id
    then
      notify("the pending review changed; run :PiClear again to confirm the current review", vim.log.levels.WARN)
      return
    end

    local saved, save_error = draft.save(draft_root, draft_target, {}, nil)
    if not saved then
      notify(save_error or "could not save the cleared draft", vim.log.levels.ERROR)
      return
    end
    annotations.clear()
    pending_submission = nil
    notify(string.format("cleared %d pending comment%s", count, count == 1 and "" or "s"))
  end)
end

local function overview_lines()
  local target = active_session or draft_target
  local submission_text = pending_submission
    and ("stable retry snapshot " .. pending_submission.submissionId)
    or "draft (no submission ID assigned)"
  local lines = {
    "# Pending Pi review",
    "",
    "Project: `" .. (draft_root or "none") .. "`",
    "Target: " .. display_name(target),
    "Bridge: " .. client_state,
    "Submission: " .. submission_text,
    string.format("Comments: %d", annotations.count()),
    "",
  }
  local line_ids = {}
  for index, record in ipairs(annotations.list()) do
    local location = record.start_line == record.end_line
      and tostring(record.start_line)
      or string.format("%d-%d", record.start_line, record.end_line)
    local modified = record.modified and " **[modified buffer]**" or ""
    local start = #lines + 1
    lines[#lines + 1] = string.format("## %d. `%s:%s`%s", index, record.path, location, modified)
    lines[#lines + 1] = ""
    for _, comment_line in ipairs(vim.split(record.comment, "\n", { plain = true })) do
      lines[#lines + 1] = comment_line
    end
    lines[#lines + 1] = ""
    for line = start, #lines do
      line_ids[line] = record.id
    end
  end
  return lines, line_ids
end

local function preview_lines(snapshot)
  local target = active_session
  local lines = {
    "# Exact Pi review snapshot",
    "",
    "Target: " .. display_name(target),
    "Target session ID: `" .. target.sessionId .. "`",
    "Project: `" .. snapshot.projectRoot .. "`",
    "Submission ID: `" .. snapshot.submissionId .. "`",
    "Created: " .. snapshot.createdAt,
    "Delivery attempted: " .. (snapshot.attempted == false and "no" or "yes or unknown"),
    "",
    "This immutable snapshot is the exact payload that retry and submit will send.",
    "",
  }

  if snapshot.risks == nil then
    lines[#lines + 1] = "## Submission warning"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "- Source-risk metadata is unavailable for this restored snapshot. Check every excerpt before sending."
    lines[#lines + 1] = ""
  elseif #snapshot.risks > 0 then
    lines[#lines + 1] = "## Submission warnings"
    lines[#lines + 1] = ""
    for _, risk in ipairs(snapshot.risks) do
      local location = risk.startLine == risk.endLine
        and tostring(risk.startLine)
        or string.format("%d-%d", risk.startLine, risk.endLine)
      local reasons = {}
      if risk.modifiedBuffer then
        reasons[#reasons + 1] = "excerpt comes from a buffer with unsaved changes"
      end
      if risk.sourceChanged then
        reasons[#reasons + 1] = "source context changed after the comment was written"
      end
      if risk.baselineUnavailable then
        reasons[#reasons + 1] = "original source context is unavailable"
      end
      lines[#lines + 1] = string.format("- `%s:%s`: %s.", risk.path, location, table.concat(reasons, "; "))
    end
    lines[#lines + 1] = ""
  else
    lines[#lines + 1] = "Submission warnings: none."
    lines[#lines + 1] = ""
  end

  for index, item in ipairs(snapshot.annotations) do
    local location = item.startLine == item.endLine
      and tostring(item.startLine)
      or string.format("%d-%d", item.startLine, item.endLine)
    lines[#lines + 1] = string.format("## Comment %d — `%s:%s`", index, item.path, location)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Review comment:"
    for _, comment_line in ipairs(vim.split(item.comment, "\n", { plain = true })) do
      lines[#lines + 1] = "> " .. comment_line
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Source excerpt:"
    for source_index, source_line in ipairs(item.source) do
      lines[#lines + 1] = string.format("    %d | %s", item.startLine + source_index - 1, source_line)
    end
    lines[#lines + 1] = ""
  end
  return lines
end

function M.preview()
  if not ensure_workspace() then
    return
  end
  if client_state == "submitting" or client_state == "connecting" then
    notify("wait for the current Pi request before previewing comments", vim.log.levels.WARN)
    return
  end
  if not active_session or client_state ~= "ready" then
    notify("select a live session with :Pi before creating an exact preview", vim.log.levels.WARN)
    return
  end
  if annotations.count() == 0 then
    notify("there are no comments to preview", vim.log.levels.WARN)
    return
  end
  if pending_submission and pending_submission.sessionId ~= active_session.sessionId then
    notify("the retry snapshot belongs to another Pi session; use :Pi to rebind it explicitly", vim.log.levels.WARN)
    return
  end

  local snapshot, _, prepare_error = prepare_submission_snapshot()
  if not snapshot then
    notify(prepare_error, vim.log.levels.ERROR)
    return
  end
  local lines = preview_lines(snapshot)
  local cancel_on_close = snapshot.attempted == false
  local function cancel_preview_snapshot()
    if not cancel_on_close
      or not pending_submission
      or pending_submission.submissionId ~= snapshot.submissionId
      or pending_submission.attempted ~= false
    then
      return
    end
    local saved, save_error = draft.save(draft_root, draft_target, annotations.serialize(), nil)
    if not saved then
      notify(save_error or "could not cancel the preview snapshot", vim.log.levels.ERROR)
    else
      pending_submission = nil
    end
  end

  local footer = cancel_on_close and " s submit · q cancel snapshot " or " s retry · q close "
  local _, modal_error = modal.preview({ lines = lines, footer = footer }, function(action)
    if action == "submit" then
      M.submit()
      return
    end
    cancel_preview_snapshot()
    vim.schedule(M.comments)
  end)
  if modal_error then
    cancel_preview_snapshot()
    notify("could not open submission preview: " .. modal_error, vim.log.levels.ERROR)
  end
end

function M.comments()
  if not ensure_workspace() then
    return
  end
  local lines, line_ids = overview_lines()
  local _, modal_error = modal.review({ lines = lines, line_ids = line_ids }, function(result)
    if not result or result.action == "close" then
      return
    end
    if result.action == "submit" then
      M.submit()
      return
    end
    if result.action == "preview" then
      M.preview()
      return
    end
    if not result.id then
      notify("move the cursor to a comment first", vim.log.levels.WARN)
      vim.schedule(M.comments)
      return
    end
    if result.action == "jump" then
      local _, jump_error = annotations.jump(result.id)
      if jump_error then
        notify(jump_error, vim.log.levels.ERROR)
      end
      return
    end
    if snapshot_contains(result.id) then
      notify("this comment is part of the stable retry snapshot; use :PiClear to cancel it", vim.log.levels.WARN)
      vim.schedule(M.comments)
      return
    end
    if result.action == "delete" then
      local remaining = {}
      for _, item in ipairs(annotations.serialize()) do
        if item.id ~= result.id then
          remaining[#remaining + 1] = item
        end
      end
      local saved, save_error = draft.save(draft_root, draft_target, remaining, pending_submission)
      if not saved then
        notify(save_error or "could not save the updated draft", vim.log.levels.ERROR)
      else
        annotations.delete(result.id)
      end
      vim.schedule(M.comments)
      return
    end
    if result.action == "edit" then
      local record = annotations.get(result.id)
      if not record then
        notify("comment no longer exists", vim.log.levels.WARN)
        return
      end
      local _, input_error = modal.input({
        title = "Edit Pi comment · " .. record.path,
        initial_text = record.comment,
      }, function(comment)
        if comment and vim.trim(comment) ~= "" and #comment <= 16 * 1024 then
          local updated = annotations.serialize()
          for _, item in ipairs(updated) do
            if item.id == result.id then
              item.comment = comment
            end
          end
          local saved, save_error = draft.save(draft_root, draft_target, updated, pending_submission)
          if not saved then
            notify(save_error or "could not save the updated draft", vim.log.levels.ERROR)
          else
            local _, update_error = annotations.update(result.id, comment)
            if update_error then
              notify(update_error, vim.log.levels.ERROR)
            end
          end
        elseif comment ~= nil then
          notify("comment was not changed because it is empty or too large", vim.log.levels.WARN)
        end
        vim.schedule(M.comments)
      end)
      if input_error then
        notify("could not open comment editor: " .. input_error, vim.log.levels.ERROR)
      end
    end
  end)
  if modal_error then
    notify("could not open review overview: " .. modal_error, vim.log.levels.ERROR)
  end
end

function M.status()
  ensure_workspace()
  return {
    active_session = active_session,
    target = draft_target,
    project_root = draft_root,
    pending_comments = annotations.count(),
    submission_id = pending_submission and pending_submission.submissionId or nil,
    client_state = client_state,
    submitting = client_state == "submitting",
  }
end

local group = vim.api.nvim_create_augroup("PiNvimReviewDraft", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
  group = group,
  callback = function(args)
    annotations.attach(args.buf)
  end,
})
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
  group = group,
  callback = schedule_persist,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    persist_workspace(false)
  end,
})

return M
