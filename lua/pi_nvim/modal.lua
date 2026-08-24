local M = {}

local active

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function available_height()
  return math.max(1, vim.o.lines - vim.o.cmdheight)
end

local function centered_config(width, height, title, footer)
  return {
    relative = "editor",
    row = math.max(0, math.floor((available_height() - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    zindex = 60,
  }
end

local function below_line_config(source_window, target_line, width, height, title, footer)
  if not valid_window(source_window) or not target_line or target_line < 1 then
    return centered_config(width, height, title, footer)
  end

  local position = vim.fn.screenpos(source_window, target_line, 1)
  if type(position) ~= "table" or position.row == 0 then
    return centered_config(width, height, title, footer)
  end

  -- screenpos() uses one-based rows. A zero-based float row with the same
  -- value starts directly below the source line.
  local row = position.row
  local space_below = available_height() - row - 2
  if space_below < 3 then
    return centered_config(width, height, title, footer)
  end

  height = math.min(height, space_below)
  local col = math.max(0, math.min(position.col - 1, vim.o.columns - width - 2))
  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    zindex = 60,
  }
end

local function set_window_options(window)
  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true
  vim.wo[window].cursorline = false
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].foldcolumn = "0"
  vim.wo[window].winblend = 0
end

local function create_buffer(name)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  return buffer
end

local function finish(value)
  local current = active
  if not current then
    return
  end
  active = nil

  if valid_window(current.window) and vim.api.nvim_get_current_win() == current.window then
    pcall(vim.cmd.stopinsert)
  end
  if valid_window(current.window) then
    pcall(vim.api.nvim_win_close, current.window, true)
  end
  if valid_buffer(current.buffer) then
    pcall(vim.api.nvim_buf_delete, current.buffer, { force = true })
  end
  if valid_window(current.return_window) then
    pcall(vim.api.nvim_set_current_win, current.return_window)
  end

  vim.schedule(function()
    current.callback(value)
  end)
end

local function watch_close(window)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(window),
    once = true,
    callback = function()
      if active and active.window == window then
        finish(nil)
      end
    end,
  })
end

local function open(buffer, window_config, callback)
  if active then
    return nil, "another Pi modal is already open"
  end

  local return_window = vim.api.nvim_get_current_win()
  local ok, window = pcall(vim.api.nvim_open_win, buffer, true, window_config)
  if not ok then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    return nil, tostring(window)
  end

  active = {
    buffer = buffer,
    window = window,
    return_window = return_window,
    callback = callback,
  }
  set_window_options(window)
  watch_close(window)
  return window
end

local function title_text(title, width)
  return " " .. vim.fn.strcharpart(title, 0, math.max(1, width - 4)) .. " "
end

function M.select(items, options, callback)
  if active then
    return nil, "another Pi modal is already open"
  end
  options = options or {}
  local labels = {}
  local longest = 0
  for index, item in ipairs(items) do
    local label = options.format_item and options.format_item(item) or tostring(item)
    labels[index] = "  " .. label
    longest = math.max(longest, vim.fn.strdisplaywidth(labels[index]))
  end

  local maximum_width = math.max(1, vim.o.columns - 4)
  local width = math.max(1, math.min(math.max(longest + 2, 48), maximum_width))
  local height = math.max(1, math.min(#labels, 12, available_height() - 4))
  local buffer = create_buffer("pi-nvim://sessions")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, labels)
  vim.bo[buffer].modifiable = false

  local title = title_text(options.title or "Pi sessions", width)
  local window, open_error = open(
    buffer,
    centered_config(width, height, title, " <Enter> select · <Esc> cancel "),
    callback
  )
  if not window then
    return nil, open_error
  end

  vim.wo[window].cursorline = true
  local function choose()
    local index = vim.api.nvim_win_get_cursor(window)[1]
    finish(items[index])
  end
  local map_options = { buffer = buffer, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", choose, map_options)
  vim.keymap.set("n", "<2-LeftMouse>", choose, map_options)
  vim.keymap.set("n", "<Esc>", function() finish(nil) end, map_options)
  vim.keymap.set("n", "q", function() finish(nil) end, map_options)
  vim.keymap.set("n", "<C-c>", function() finish(nil) end, map_options)
  vim.keymap.set("n", "<C-n>", "j", map_options)
  vim.keymap.set("n", "<C-p>", "k", map_options)
  return window
end

function M.input(options, callback)
  if active then
    return nil, "another Pi modal is already open"
  end
  options = options or {}
  local width = math.max(1, math.min(options.width or 72, vim.o.columns - 4))
  local height = math.max(1, math.min(options.height or 8, available_height() - 4))
  local buffer = create_buffer("pi-nvim://comment")
  vim.bo[buffer].filetype = "markdown"
  if type(options.initial_text) == "string" and options.initial_text ~= "" then
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(options.initial_text, "\n", { plain = true }))
  end

  local title = title_text(options.title or "Pi comment", width)
  local window_config = below_line_config(
    options.source_window,
    options.target_line,
    width,
    height,
    title,
    " <C-s> submit · <Esc> cancel "
  )
  local window, open_error = open(buffer, window_config, callback)
  if not window then
    return nil, open_error
  end

  local function submit()
    if not valid_buffer(buffer) then
      finish(nil)
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    finish(table.concat(lines, "\n"))
  end
  local function cancel()
    finish(nil)
  end
  local map_options = { buffer = buffer, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, map_options)
  vim.keymap.set({ "n", "i" }, "<Esc>", cancel, map_options)
  vim.keymap.set("n", "q", cancel, map_options)
  vim.keymap.set({ "n", "i" }, "<C-c>", cancel, map_options)

  vim.schedule(function()
    if valid_window(window) then
      vim.api.nvim_set_current_win(window)
      local last_line = vim.api.nvim_buf_line_count(buffer)
      local last_text = vim.api.nvim_buf_get_lines(buffer, last_line - 1, last_line, false)[1] or ""
      vim.api.nvim_win_set_cursor(window, { last_line, #last_text })
      vim.cmd.startinsert()
    end
  end)
  return window
end

function M.review(options, callback)
  if active then
    return nil, "another Pi modal is already open"
  end
  options = options or {}
  local width = math.max(1, math.min(options.width or 88, vim.o.columns - 4))
  local height = math.max(1, math.min(options.height or 24, available_height() - 4))
  local buffer = create_buffer("pi-nvim://comments")
  vim.bo[buffer].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, options.lines or { "No pending comments" })
  vim.bo[buffer].modifiable = false

  local window, open_error = open(
    buffer,
    centered_config(
      width,
      height,
      title_text(options.title or "Pi review overview", width),
      " <Enter> jump · e edit · d delete · p preview · s submit · q close "
    ),
    callback
  )
  if not window then
    return nil, open_error
  end

  vim.wo[window].cursorline = true
  local function action(name)
    local line = vim.api.nvim_win_get_cursor(window)[1]
    local id = options.line_ids and options.line_ids[line] or nil
    finish({ action = name, id = id })
  end
  local map_options = { buffer = buffer, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function() action("jump") end, map_options)
  vim.keymap.set("n", "e", function() action("edit") end, map_options)
  vim.keymap.set("n", "d", function() action("delete") end, map_options)
  vim.keymap.set("n", "p", function() action("preview") end, map_options)
  vim.keymap.set("n", "s", function() action("submit") end, map_options)
  vim.keymap.set("n", "q", function() finish({ action = "close" }) end, map_options)
  vim.keymap.set("n", "<Esc>", function() finish({ action = "close" }) end, map_options)
  vim.keymap.set("n", "<C-c>", function() finish({ action = "close" }) end, map_options)
  return window
end

function M.preview(options, callback)
  if active then
    return nil, "another Pi modal is already open"
  end
  options = options or {}
  local width = math.max(1, math.min(options.width or 96, vim.o.columns - 4))
  local height = math.max(1, math.min(options.height or 28, available_height() - 4))
  local buffer = create_buffer("pi-nvim://preview")
  vim.bo[buffer].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, options.lines or {})
  vim.bo[buffer].modifiable = false

  local window, open_error = open(
    buffer,
    centered_config(
      width,
      height,
      title_text(options.title or "Pi submission preview", width),
      options.footer or " s submit · q close "
    ),
    callback
  )
  if not window then
    return nil, open_error
  end

  local map_options = { buffer = buffer, silent = true, nowait = true }
  vim.keymap.set("n", "s", function() finish("submit") end, map_options)
  vim.keymap.set("n", "q", function() finish(nil) end, map_options)
  vim.keymap.set("n", "<Esc>", function() finish(nil) end, map_options)
  vim.keymap.set("n", "<C-c>", function() finish(nil) end, map_options)
  return window
end

function M.close()
  finish(nil)
end

function M.is_open()
  return active ~= nil
end

return M
