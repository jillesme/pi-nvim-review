local uv = vim.uv

local M = {}
local FORMAT_VERSION = 1
local MAX_DRAFT_BYTES = 16 * 1024 * 1024
local DIRECTORY_MODE = 448 -- 0700
local FILE_MODE = 384 -- 0600

local function trusted_owner_and_mode(stat)
  if package.config:sub(1, 1) == "\\" then
    return true
  end
  local passwd = uv.os_get_passwd()
  if passwd and passwd.uid ~= nil and stat.uid ~= nil and stat.uid ~= passwd.uid then
    return false
  end
  return stat.mode == nil or bit.band(stat.mode, 63) == 0
end

local function directory()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "pi-nvim-review", "drafts")
end

local function draft_path(project_root)
  return vim.fs.joinpath(directory(), vim.fn.sha256(project_root) .. ".json")
end

local function safe_relative_path(path)
  if type(path) ~= "string"
    or path == ""
    or #path > 4096
    or path:find("\\", 1, true)
    or path:sub(1, 1) == "/"
  then
    return false
  end
  local normalized = vim.fs.normalize(path)
  return normalized == path
    and path ~= "."
    and path ~= ".."
    and path:sub(1, 3) ~= "../"
end

local function positive_integer(value, maximum)
  return type(value) == "number" and value > 0 and value <= maximum and value % 1 == 0
end

local function valid_comment(item)
  return type(item) == "table"
    and positive_integer(item.id, 1000000000)
    and positive_integer(item.order, 1000000000)
    and safe_relative_path(item.path)
    and positive_integer(item.startLine, 10000000)
    and positive_integer(item.endLine, 10000000)
    and item.endLine >= item.startLine
    and item.endLine - item.startLine + 1 <= 1000
    and type(item.comment) == "string"
    and item.comment ~= ""
    and #item.comment <= 16 * 1024
    and (item.sourceFingerprint == nil
      or (type(item.sourceFingerprint) == "string"
        and #item.sourceFingerprint == 64
        and item.sourceFingerprint:match("^%x+$") ~= nil))
end

local function valid_annotation(item)
  if type(item) ~= "table" or not valid_comment({
    id = 1,
    order = 1,
    path = item.path,
    startLine = item.startLine,
    endLine = item.endLine,
    comment = item.comment,
  }) then
    return false
  end
  if type(item.source) ~= "table" or #item.source ~= item.endLine - item.startLine + 1 then
    return false
  end
  local chars = 0
  for _, line in ipairs(item.source) do
    if type(line) ~= "string" or line:find("\n", 1, true) or line:find("\r", 1, true) then
      return false
    end
    chars = chars + #line + 1
  end
  return chars <= 64 * 1024
end

local function valid_target(target, project_root)
  if target == nil then
    return true
  end
  return type(target) == "table"
    and type(target.sessionId) == "string"
    and target.sessionId ~= ""
    and target.projectRoot == project_root
    and type(target.shortId) == "string"
    and positive_integer(target.pid, 2147483647)
    and (target.sessionName == nil or type(target.sessionName) == "string")
    and target.token == nil
end

local function valid_risks(risks, maximum)
  if risks == nil then
    return true
  end
  if type(risks) ~= "table" or #risks > maximum then
    return false
  end
  for _, risk in ipairs(risks) do
    if type(risk) ~= "table"
      or not safe_relative_path(risk.path)
      or not positive_integer(risk.startLine, 10000000)
      or not positive_integer(risk.endLine, 10000000)
      or risk.endLine < risk.startLine
      or risk.endLine - risk.startLine + 1 > 1000
      or type(risk.modifiedBuffer) ~= "boolean"
      or type(risk.sourceChanged) ~= "boolean"
      or type(risk.baselineUnavailable) ~= "boolean"
    then
      return false
    end
  end
  return true
end

local function valid_submission(submission, project_root, known_ids)
  if submission == nil then
    return true
  end
  if type(submission) ~= "table"
    or type(submission.submissionId) ~= "string"
    or submission.submissionId == ""
    or #submission.submissionId > 128
    or not submission.submissionId:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$")
    or type(submission.sessionId) ~= "string"
    or submission.sessionId == ""
    or submission.projectRoot ~= project_root
    or type(submission.createdAt) ~= "string"
    or (submission.attempted ~= nil and type(submission.attempted) ~= "boolean")
    or type(submission.ids) ~= "table"
    or type(submission.annotations) ~= "table"
    or #submission.ids == 0
    or #submission.ids ~= #submission.annotations
    or not valid_risks(submission.risks, #submission.annotations)
  then
    return false
  end
  local snapshot_ids = {}
  for index, id in ipairs(submission.ids) do
    if snapshot_ids[id]
      or not positive_integer(id, 1000000000)
      or not known_ids[id]
      or not valid_annotation(submission.annotations[index])
    then
      return false
    end
    snapshot_ids[id] = true
  end
  return true
end

local function validate(data, project_root)
  if type(data) ~= "table"
    or data.version ~= FORMAT_VERSION
    or data.projectRoot ~= project_root
    or type(data.savedAt) ~= "string"
    or type(data.comments) ~= "table"
    or not valid_target(data.target, project_root)
  then
    return nil, "Draft metadata is invalid"
  end

  local ids = {}
  for _, item in ipairs(data.comments) do
    if not valid_comment(item) or ids[item.id] then
      return nil, "Draft comments are invalid"
    end
    ids[item.id] = true
  end
  if not valid_submission(data.submission, project_root, ids) then
    return nil, "Draft submission snapshot is invalid"
  end
  return data
end

local function ensure_directory()
  local path = directory()
  local ok, error_message = pcall(vim.fn.mkdir, path, "p", DIRECTORY_MODE)
  if not ok then
    return nil, tostring(error_message)
  end
  local stat = uv.fs_lstat(path)
  if not stat or stat.type ~= "directory" or not trusted_owner_and_mode(stat) then
    return nil, "Draft path is not a private user directory: " .. path
  end
  pcall(uv.fs_chmod, path, DIRECTORY_MODE)
  return path
end

function M.load(project_root)
  local path = draft_path(project_root)
  local stat = uv.fs_lstat(path)
  if not stat then
    return nil
  end
  if stat.type ~= "file" or stat.size > MAX_DRAFT_BYTES or not trusted_owner_and_mode(stat) then
    return nil, "Draft is not a private regular file: " .. path
  end

  local fd, open_error = uv.fs_open(path, "r", FILE_MODE)
  if not fd then
    return nil, "Could not open draft: " .. tostring(open_error)
  end
  local current = uv.fs_fstat(fd)
  if not current or current.type ~= "file" or current.size > MAX_DRAFT_BYTES or not trusted_owner_and_mode(current) then
    uv.fs_close(fd)
    return nil, "Draft changed while it was opened"
  end
  local contents, read_error = uv.fs_read(fd, current.size, 0)
  uv.fs_close(fd)
  if not contents then
    return nil, "Could not read draft: " .. tostring(read_error)
  end

  local ok, data = pcall(vim.json.decode, contents)
  if not ok then
    return nil, "Draft JSON is corrupt; the file was kept at " .. path
  end
  local validation_ok, valid, validation_error = pcall(validate, data, project_root)
  if not validation_ok then
    return nil, "Draft data is corrupt; the file was kept at " .. path
  end
  return valid, validation_error
end

function M.save(project_root, target, comments, submission)
  local path, directory_error = ensure_directory()
  if not path then
    return nil, directory_error
  end

  local data = {
    version = FORMAT_VERSION,
    projectRoot = project_root,
    savedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    target = target,
    comments = comments,
    submission = submission,
  }
  local valid, validation_error = validate(data, project_root)
  if not valid then
    return nil, validation_error
  end

  local encode_ok, encoded = pcall(vim.json.encode, data)
  if not encode_ok then
    return nil, "Could not encode draft: " .. tostring(encoded)
  end
  encoded = encoded .. "\n"
  if #encoded > MAX_DRAFT_BYTES then
    return nil, "Draft is larger than 16 MiB"
  end

  local target_path = draft_path(project_root)
  local temporary = target_path .. "." .. tostring(uv.os_getpid()) .. "." .. tostring(uv.hrtime()) .. ".tmp"
  local fd, open_error = uv.fs_open(temporary, "wx", FILE_MODE)
  if not fd then
    return nil, "Could not create draft: " .. tostring(open_error)
  end

  local written, write_error = uv.fs_write(fd, encoded, 0)
  if not written or written ~= #encoded then
    uv.fs_close(fd)
    pcall(uv.fs_unlink, temporary)
    return nil, "Could not write draft: " .. tostring(write_error)
  end
  local synced, sync_error = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not synced then
    pcall(uv.fs_unlink, temporary)
    return nil, "Could not sync draft: " .. tostring(sync_error)
  end
  pcall(uv.fs_chmod, temporary, FILE_MODE)

  local renamed, rename_error = uv.fs_rename(temporary, target_path)
  if not renamed then
    pcall(uv.fs_unlink, temporary)
    return nil, "Could not install draft: " .. tostring(rename_error)
  end
  pcall(uv.fs_chmod, target_path, FILE_MODE)
  return true
end

function M.remove(project_root)
  local path = draft_path(project_root)
  local removed, error_message, code = uv.fs_unlink(path)
  if removed or code == "ENOENT" then
    return true
  end
  return nil, "Could not remove draft: " .. tostring(error_message)
end

return M
