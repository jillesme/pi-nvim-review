local M = {}

local namespace = vim.api.nvim_create_namespace("pi_nvim_comments")
local records = {}
local next_id = 1

local MAX_SOURCE_LINES = 1000
local MAX_SOURCE_CHARS = 64 * 1024

vim.api.nvim_set_hl(0, "PiNvimComment", { default = true, link = "DiagnosticInfo" })

local function comment_summary(comment)
  local single_line = comment:gsub("%s+", " ")
  local summary = vim.fn.strcharpart(single_line, 0, 80)
  if vim.fn.strchars(single_line) > 80 then
    summary = summary .. "…"
  end
  return summary
end

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function loaded_buffer(buffer)
  return valid_buffer(buffer) and vim.api.nvim_buf_is_loaded(buffer)
end

local function set_mark(record)
  if not loaded_buffer(record.bufnr) then
    return nil
  end
  if record.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, record.bufnr, namespace, record.mark_id)
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, record.bufnr, namespace, record.start_line - 1, 0, {
    end_row = record.end_line - 1,
    end_col = -1,
    strict = false,
    right_gravity = false,
    end_right_gravity = true,
    sign_text = "Pi",
    sign_hl_group = "PiNvimComment",
    virt_text = { { " Pi: " .. comment_summary(record.comment), "PiNvimComment" } },
    virt_text_pos = "eol",
    priority = 150,
  })
  if not ok then
    return tostring(mark_id)
  end
  record.mark_id = mark_id
  return nil
end

local function current_range(record)
  if loaded_buffer(record.bufnr) and record.mark_id then
    local ok, mark = pcall(
      vim.api.nvim_buf_get_extmark_by_id,
      record.bufnr,
      namespace,
      record.mark_id,
      { details = true }
    )
    if ok and type(mark) == "table" and #mark >= 2 then
      local details = mark[3] or {}
      local start_row = mark[1]
      local end_row = type(details.end_row) == "number" and details.end_row or start_row
      return start_row + 1, math.max(start_row, end_row) + 1
    end
  end
  return record.start_line, record.end_line
end

local function refresh_range(record)
  record.start_line, record.end_line = current_range(record)
end

local function find_record(id)
  for index, record in ipairs(records) do
    if record.id == id then
      return record, index
    end
  end
end

function M.count()
  return #records
end

function M.add(bufnr, absolute_path, relative_path, start_line, end_line, comment)
  local id = next_id
  next_id = next_id + 1
  local record = {
    id = id,
    order = id,
    bufnr = bufnr,
    absolute_path = absolute_path,
    path = relative_path,
    start_line = start_line,
    end_line = end_line,
    comment = comment,
  }
  local mark_error = set_mark(record)
  if mark_error then
    return nil, mark_error
  end
  records[#records + 1] = record
  return id
end

function M.attach(bufnr)
  if not loaded_buffer(bufnr) then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local absolute_path = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
  for _, record in ipairs(records) do
    if record.absolute_path == absolute_path and record.bufnr ~= bufnr then
      record.bufnr = bufnr
      record.mark_id = nil
      set_mark(record)
    elseif record.absolute_path == absolute_path and not record.mark_id then
      set_mark(record)
    end
  end
end

function M.restore(project_root, items)
  M.reset()
  local maximum_id = 0
  for _, item in ipairs(items or {}) do
    local absolute_path = vim.fs.joinpath(project_root, item.path)
    local bufnr = vim.fn.bufnr(absolute_path)
    if bufnr < 0 then
      bufnr = nil
    end
    local record = {
      id = item.id,
      order = item.order,
      bufnr = bufnr,
      absolute_path = absolute_path,
      path = item.path,
      start_line = item.startLine,
      end_line = item.endLine,
      comment = item.comment,
    }
    records[#records + 1] = record
    maximum_id = math.max(maximum_id, record.id)
    if loaded_buffer(bufnr) then
      set_mark(record)
    end
  end
  next_id = maximum_id + 1
end

function M.list()
  local result = {}
  for _, record in ipairs(records) do
    refresh_range(record)
    result[#result + 1] = {
      id = record.id,
      order = record.order,
      path = record.path,
      absolute_path = record.absolute_path,
      start_line = record.start_line,
      end_line = record.end_line,
      comment = record.comment,
      modified = loaded_buffer(record.bufnr) and vim.bo[record.bufnr].modified or false,
    }
  end
  table.sort(result, function(left, right)
    return left.order < right.order
  end)
  return result
end

function M.serialize()
  local result = {}
  for _, record in ipairs(M.list()) do
    result[#result + 1] = {
      id = record.id,
      order = record.order,
      path = record.path,
      startLine = record.start_line,
      endLine = record.end_line,
      comment = record.comment,
    }
  end
  return result
end

function M.get(id)
  for _, record in ipairs(M.list()) do
    if record.id == id then
      return record
    end
  end
end

function M.update(id, comment)
  local record = find_record(id)
  if not record then
    return nil, "Comment no longer exists"
  end
  refresh_range(record)
  record.comment = comment
  local mark_error = set_mark(record)
  if mark_error then
    return nil, mark_error
  end
  return true
end

function M.delete(id)
  local record, index = find_record(id)
  if not record then
    return false
  end
  if valid_buffer(record.bufnr) and record.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, record.bufnr, namespace, record.mark_id)
  end
  table.remove(records, index)
  return true
end

function M.jump(id)
  local record = find_record(id)
  if not record then
    return nil, "Comment no longer exists"
  end
  refresh_range(record)
  local ok, error_message = pcall(vim.cmd.edit, vim.fn.fnameescape(record.absolute_path))
  if not ok then
    return nil, tostring(error_message)
  end
  record.bufnr = vim.api.nvim_get_current_buf()
  if not record.mark_id then
    set_mark(record)
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { record.start_line, 0 })
  return true
end

local function source_from_buffer(record, start_line, end_line)
  if not loaded_buffer(record.bufnr) then
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(record.bufnr)
  if start_line > line_count then
    return nil
  end
  end_line = math.min(end_line, line_count)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, record.bufnr, start_line - 1, end_line, false)
  return ok and lines or nil
end

local function source_from_file(record, end_line)
  local ok, lines = pcall(vim.fn.readfile, record.absolute_path, "", end_line)
  return ok and lines or nil
end

local function source_lines(record, start_line, end_line)
  local lines = source_from_buffer(record, start_line, end_line)
  if not lines then
    local file_lines = source_from_file(record, end_line)
    if not file_lines then
      return nil, "Could not read " .. record.path
    end
    lines = {}
    for line = start_line, end_line do
      lines[#lines + 1] = file_lines[line] or ""
    end
  end

  local expected = end_line - start_line + 1
  while #lines < expected do
    lines[#lines + 1] = ""
  end

  local chars = 0
  for _, line in ipairs(lines) do
    chars = chars + #line + 1
  end
  if chars > MAX_SOURCE_CHARS then
    return nil, string.format("Source excerpt for %s:%d-%d is larger than 64 KiB", record.path, start_line, end_line)
  end
  return lines
end

function M.build()
  local resolved = {}
  for _, record in ipairs(records) do
    local start_line, end_line = current_range(record)
    if end_line - start_line + 1 > MAX_SOURCE_LINES then
      return nil, nil, string.format("Annotation at %s:%d is now longer than %d lines", record.path, start_line, MAX_SOURCE_LINES)
    end

    local source, source_error = source_lines(record, start_line, end_line)
    if not source then
      return nil, nil, source_error
    end

    resolved[#resolved + 1] = {
      id = record.id,
      order = record.order,
      path = record.path,
      startLine = start_line,
      endLine = end_line,
      comment = record.comment,
      source = source,
    }
  end

  table.sort(resolved, function(left, right)
    if left.path ~= right.path then
      return left.path < right.path
    end
    if left.startLine ~= right.startLine then
      return left.startLine < right.startLine
    end
    if left.endLine ~= right.endLine then
      return left.endLine < right.endLine
    end
    return left.order < right.order
  end)

  local payload = {}
  local ids = {}
  for _, annotation in ipairs(resolved) do
    ids[#ids + 1] = annotation.id
    payload[#payload + 1] = {
      path = annotation.path,
      startLine = annotation.startLine,
      endLine = annotation.endLine,
      comment = annotation.comment,
      source = annotation.source,
    }
  end
  return payload, ids
end

function M.clear(ids)
  local selected
  if ids then
    selected = {}
    for _, id in ipairs(ids) do
      selected[id] = true
    end
  end

  local kept = {}
  for _, record in ipairs(records) do
    if not selected or selected[record.id] then
      if valid_buffer(record.bufnr) and record.mark_id then
        pcall(vim.api.nvim_buf_del_extmark, record.bufnr, namespace, record.mark_id)
      end
    else
      kept[#kept + 1] = record
    end
  end
  records = kept
end

function M.reset()
  M.clear()
  next_id = 1
end

return M
