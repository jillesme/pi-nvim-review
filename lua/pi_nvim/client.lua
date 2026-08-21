local uv = vim.uv

local M = {}
local MAX_REQUEST_BYTES = 1024 * 1024
local MAX_RESPONSE_BYTES = 64 * 1024

local function valid_response(response)
  if type(response) ~= "table" or response.protocolVersion ~= 1 or type(response.ok) ~= "boolean" then
    return false
  end
  if response.ok then
    return response.type == "pong" or response.type == "submitted"
  end
  return type(response.error) == "string" and response.error ~= ""
end

function M.request(manifest, request, timeout_ms, callback)
  local ok, encoded = pcall(vim.json.encode, request)
  if not ok then
    callback("Could not encode bridge request: " .. tostring(encoded))
    return
  end

  local wire = encoded .. "\n"
  if #wire > MAX_REQUEST_BYTES then
    callback("Bridge request is larger than 1 MiB")
    return
  end

  local socket = uv.new_tcp()
  local timer = uv.new_timer()
  local finished = false
  local reading = false
  local response_text = ""

  local function close_handle(handle)
    if handle and not handle:is_closing() then
      handle:close()
    end
  end

  local function finish(err, response)
    if finished then
      return
    end
    finished = true

    if timer then
      timer:stop()
      close_handle(timer)
    end
    if reading then
      pcall(socket.read_stop, socket)
    end
    close_handle(socket)

    vim.schedule(function()
      callback(err, response)
    end)
  end

  timer:start(timeout_ms, 0, function()
    finish(string.format("Connection to Pi session %s timed out", manifest.shortId))
  end)

  socket:connect(manifest.host, manifest.port, function(connect_error)
    if connect_error then
      finish("Could not connect to Pi session " .. manifest.shortId .. ": " .. connect_error)
      return
    end

    reading = true
    socket:read_start(function(read_error, chunk)
      if read_error then
        finish("Could not read Pi bridge response: " .. read_error)
        return
      end
      if not chunk then
        finish("Pi bridge closed before it returned a response")
        return
      end

      response_text = response_text .. chunk
      if #response_text > MAX_RESPONSE_BYTES then
        finish("Pi bridge response is too large")
        return
      end

      local newline = response_text:find("\n", 1, true)
      if not newline then
        return
      end

      if response_text:sub(newline + 1):find("%S") then
        finish("Pi bridge returned more than one response")
        return
      end

      local decode_ok, response = pcall(vim.json.decode, response_text:sub(1, newline - 1))
      if not decode_ok or not valid_response(response) then
        finish("Pi bridge returned an invalid response")
        return
      end
      if not response.ok then
        finish(response.error)
        return
      end
      finish(nil, response)
    end)

    socket:write(wire, function(write_error)
      if write_error then
        finish("Could not send request to Pi bridge: " .. write_error)
      end
    end)
  end)
end

return M
