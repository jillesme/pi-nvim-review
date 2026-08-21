local uv = vim.uv

local M = {}
local MAX_MANIFEST_BYTES = 64 * 1024

local function user_key()
  local passwd = uv.os_get_passwd()
  local identity = passwd and (passwd.uid ~= nil and tostring(passwd.uid) or passwd.username) or "unknown"
  return (identity:gsub("[^A-Za-z0-9_.-]", "_"))
end

function M.directory(override)
  local configured = override or vim.env.PI_NVIM_REGISTRY
  if configured and configured ~= "" then
    return vim.fs.normalize(vim.fn.fnamemodify(configured, ":p"))
  end
  return vim.fs.joinpath(uv.os_tmpdir(), "pi-nvim-" .. user_key())
end

function M.canonical(path)
  return uv.fs_realpath(path) or vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return nil
  end

  local stat = uv.fs_fstat(fd)
  if not stat or stat.type ~= "file" or stat.size > MAX_MANIFEST_BYTES then
    uv.fs_close(fd)
    return nil
  end

  local contents = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return contents
end

local function decode_manifest(path)
  local contents = read_file(path)
  if not contents then
    return nil
  end

  local ok, manifest = pcall(vim.json.decode, contents)
  if not ok or type(manifest) ~= "table" then
    return nil
  end
  return manifest
end

local function valid_manifest(manifest)
  return manifest.protocolVersion == 1
    and type(manifest.sessionId) == "string"
    and manifest.sessionId ~= ""
    and type(manifest.shortId) == "string"
    and #manifest.shortId == 5
    and type(manifest.projectRoot) == "string"
    and manifest.projectRoot ~= ""
    and type(manifest.pid) == "number"
    and manifest.pid > 0
    and manifest.pid % 1 == 0
    and manifest.host == "127.0.0.1"
    and type(manifest.port) == "number"
    and manifest.port > 0
    and manifest.port <= 65535
    and manifest.port % 1 == 0
    and type(manifest.token) == "string"
    and #manifest.token >= 32
    and type(manifest.startedAt) == "string"
    and (manifest.sessionName == nil or type(manifest.sessionName) == "string")
end

local function process_is_alive(pid)
  local ok, result = pcall(uv.kill, pid, 0)
  return ok and result ~= nil
end

function M.remove(manifest)
  if type(manifest) ~= "table" or type(manifest._path) ~= "string" then
    return
  end

  local current = decode_manifest(manifest._path)
  if current
    and current.sessionId == manifest.sessionId
    and current.token == manifest.token
  then
    pcall(uv.fs_unlink, manifest._path)
  end
end

function M.discover(project_root, override)
  local directory = M.directory(override)
  local scan = uv.fs_scandir(directory)
  if not scan then
    return {}
  end

  local sessions = {}
  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end

    if kind == "file" and name:sub(-5) == ".json" then
      local path = vim.fs.joinpath(directory, name)
      local manifest = decode_manifest(path)
      if valid_manifest(manifest) and M.canonical(manifest.projectRoot) == project_root then
        manifest._path = path
        if process_is_alive(manifest.pid) then
          sessions[#sessions + 1] = manifest
        else
          M.remove(manifest)
        end
      end
    end
  end

  table.sort(sessions, function(left, right)
    if left.startedAt == right.startedAt then
      return left.sessionId < right.sessionId
    end
    return left.startedAt > right.startedAt
  end)
  return sessions
end

return M
