local annotations = require("pi_nvim.annotations")
local client = require("pi_nvim.client")
local registry = require("pi_nvim.registry")

local M = {}

local config = {
  timeout_ms = 3000,
  registry_dir = nil,
}

local active_session
local submitting = false

local function notify(message, level)
  vim.notify("pi-nvim: " .. message, level or vim.log.levels.INFO)
end

local function request_for(session, request_type)
  return {
    protocolVersion = 1,
    type = request_type,
    token = session.token,
    sessionId = session.sessionId,
    projectRoot = session.projectRoot,
  }
end

local function display_name(session)
  local name = session.sessionName
  if type(name) == "string" and name ~= "" then
    name = name:gsub("[%c]", " ")
    return string.format("%s (%s)", name, session.shortId)
  end
  return string.format("%s (pid %d)", session.shortId, session.pid)
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
end

function M.select_session()
  if submitting then
    notify("wait for the current submission before changing sessions", vim.log.levels.WARN)
    return
  end
  if annotations.count() > 0 then
    notify("submit pending comments with :PiSubmit or remove them with :PiClear before changing sessions", vim.log.levels.WARN)
    return
  end

  -- Read the working directory each time so :cd changes affect discovery.
  local root = registry.canonical(vim.uv.cwd() or vim.fn.getcwd())
  local sessions = registry.discover(root, config.registry_dir)
  if #sessions == 0 then
    notify("no live Pi Neovim sessions found for " .. root, vim.log.levels.WARN)
    return
  end

  vim.ui.select(sessions, {
    prompt = "Pi sessions for " .. root,
    kind = "pi_nvim_session",
    format_item = display_name,
  }, function(choice)
    if not choice then
      return
    end

    client.request(choice, request_for(choice, "ping"), config.timeout_ms, function(err, response)
      if err then
        registry.remove(choice)
        notify(err, vim.log.levels.ERROR)
        return
      end
      if response.type ~= "pong" or response.sessionId ~= choice.sessionId then
        registry.remove(choice)
        notify("selected Pi session returned the wrong identity", vim.log.levels.ERROR)
        return
      end

      active_session = choice
      notify("active Pi session is " .. display_name(choice))
    end)
  end)
end

function M.annotate(start_line, end_line)
  if not active_session then
    notify("select a session with :Pi first", vim.log.levels.WARN)
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
  vim.ui.input({
    prompt = string.format("Pi comment for %s:%s: ", path, location),
    scope = "line",
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

    local _, add_error = annotations.add(bufnr, absolute_path, path, start_line, end_line, comment)
    if add_error then
      notify("could not display comment: " .. add_error, vim.log.levels.ERROR)
      return
    end
    notify("comment added at " .. path .. ":" .. location)
  end)
end

function M.submit()
  if submitting then
    notify("a review submission is already in progress", vim.log.levels.WARN)
    return
  end
  if not active_session then
    notify("select a session with :Pi first", vim.log.levels.WARN)
    return
  end
  if annotations.count() == 0 then
    notify("there are no comments to submit", vim.log.levels.WARN)
    return
  end

  local payload, ids, build_error = annotations.build()
  if not payload then
    notify(build_error or "could not build review payload", vim.log.levels.ERROR)
    return
  end

  local session = active_session
  local request = request_for(session, "submit")
  request.annotations = payload
  submitting = true

  client.request(session, request, config.timeout_ms, function(err, response)
    submitting = false
    if err then
      notify(err .. "; comments were kept for retry", vim.log.levels.ERROR)
      return
    end

    local valid_status = response.status == "accepted" or response.status == "queued"
    if response.type ~= "submitted"
      or response.sessionId ~= session.sessionId
      or response.count ~= #payload
      or not valid_status
    then
      notify("Pi returned an invalid submission acknowledgement; comments were kept", vim.log.levels.ERROR)
      return
    end

    annotations.clear(ids)
    local verb = response.status == "queued" and "queued" or "submitted"
    notify(string.format("%d comment%s %s to Pi session %s", #payload, #payload == 1 and "" or "s", verb, session.shortId))
  end)
end

function M.clear()
  if submitting then
    notify("wait for the current submission before clearing comments", vim.log.levels.WARN)
    return
  end

  local count = annotations.count()
  if count == 0 then
    notify("there are no comments to clear")
    return
  end
  annotations.clear()
  notify(string.format("cleared %d pending comment%s", count, count == 1 and "" or "s"))
end

function M.status()
  return {
    active_session = active_session,
    pending_comments = annotations.count(),
    submitting = submitting,
  }
end

return M
