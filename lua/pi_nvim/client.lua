local uv = vim.uv

local M = {}
local MAX_REQUEST_BYTES = 1024 * 1024
local MAX_RESPONSE_BYTES = 64 * 1024

local error_codes = {
  invalid_json = true,
  incompatible_version = true,
  invalid_request = true,
  authentication_failed = true,
  stale_session = true,
  bridge_stopping = true,
  busy = true,
  timeout = true,
  transport_error = true,
  invalid_response = true,
  internal_error = true,
}

local function local_error(code, message, retryable, manifest, request)
  return {
    code = code,
    message = message,
    retryable = retryable,
    sessionId = manifest and manifest.sessionId or nil,
    submissionId = request and request.submissionId or nil,
  }
end

local function valid_response(response)
  if type(response) ~= "table" or response.protocolVersion ~= 2 or type(response.ok) ~= "boolean" then
    return false
  end
  if response.ok then
    if response.type == "pong" then
      return type(response.sessionId) == "string"
    end
    return response.type == "submitted"
      and type(response.sessionId) == "string"
      and type(response.submissionId) == "string"
      and (response.status == "accepted" or response.status == "queued")
      and type(response.count) == "number"
      and response.count > 0
      and response.count % 1 == 0
  end
  return error_codes[response.code] == true
    and type(response.message) == "string"
    and response.message ~= ""
    and #response.message <= 512
    and type(response.retryable) == "boolean"
    and (response.sessionId == nil or type(response.sessionId) == "string")
    and (response.submissionId == nil or type(response.submissionId) == "string")
end

function M.message(err)
  if type(err) == "table" and type(err.message) == "string" then
    return err.message
  end
  return tostring(err)
end

function M.request(manifest, request, timeout_ms, callback)
  local ok, encoded = pcall(vim.json.encode, request)
  if not ok then
    callback(local_error("invalid_request", "Could not encode bridge request: " .. tostring(encoded), false, manifest, request))
    return
  end

  local wire = encoded .. "\n"
  if #wire > MAX_REQUEST_BYTES then
    callback(local_error("invalid_request", "Bridge request is larger than 1 MiB", false, manifest, request))
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
    finish(local_error(
      "timeout",
      string.format("Connection to Pi session %s timed out", manifest.shortId),
      true,
      manifest,
      request
    ))
  end)

  socket:connect(manifest.host, manifest.port, function(connect_error)
    if connect_error then
      finish(local_error(
        "transport_error",
        "Could not connect to Pi session " .. manifest.shortId .. ": " .. connect_error,
        true,
        manifest,
        request
      ))
      return
    end

    reading = true
    socket:read_start(function(read_error, chunk)
      if read_error then
        finish(local_error(
          "transport_error",
          "Could not read Pi bridge response: " .. read_error,
          true,
          manifest,
          request
        ))
        return
      end
      if not chunk then
        finish(local_error(
          "transport_error",
          "Pi bridge closed before it returned a response",
          true,
          manifest,
          request
        ))
        return
      end

      response_text = response_text .. chunk
      if #response_text > MAX_RESPONSE_BYTES then
        finish(local_error("invalid_response", "Pi bridge response is too large", true, manifest, request))
        return
      end

      local newline = response_text:find("\n", 1, true)
      if not newline then
        return
      end

      if response_text:sub(newline + 1):find("%S") then
        finish(local_error("invalid_response", "Pi bridge returned more than one response", true, manifest, request))
        return
      end

      local decode_ok, response = pcall(vim.json.decode, response_text:sub(1, newline - 1))
      if not decode_ok or not valid_response(response) then
        finish(local_error("invalid_response", "Pi bridge returned an invalid response", true, manifest, request))
        return
      end
      if not response.ok then
        finish(response)
        return
      end
      finish(nil, response)
    end)

    socket:write(wire, function(write_error)
      if write_error then
        finish(local_error(
          "transport_error",
          "Could not send request to Pi bridge: " .. write_error,
          true,
          manifest,
          request
        ))
      end
    end)
  end)
end

return M
