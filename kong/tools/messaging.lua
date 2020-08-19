local clustering = require "kong.clustering"

local utils = require("kong.tools.utils")
local msgpack = require "MessagePack"
local mp_pack = msgpack.pack
local mp_unpack = msgpack.unpack
local cjson_encode = require "cjson".encode

local new_tab = require("table.new")
local clear_tab = require("table.clear")

local BUFFER_SIZE = 64

local _M = {}
local mt = { __index = _M }

_M.TYPE = {
  PRODUCER = 1,
  CONSUMER = 2,
}

local _log_prefix = "[messaging-utils] "


local function get_log_prefix(self)
  return _log_prefix .. "[" .. self.message_type .. "] "
end

local function get_dummy_heartbeat_msg(self)
  return cjson_encode({
    type = self.message_type,
    -- TODO: msgid for re-transmit
    -- cjson decodes nil to lightuserdata null, this is unhandled
    -- in db strategies, to avoid introducing too much change we
    -- use mp_pack to wrap inner payloads
    data = mp_pack({
      self.message_type_version,
      self.message_type,
      {},
    }),
  })
end

local ws_send_func

local function flush_cp(premature, self)
  if premature then
    return
  end

  local sent = false

  if ws_send_func then
    while true do
      local v, err = self.SHM:rpop(self.SHM_KEY)
      if err then
        ngx.log(ngx.WARN, get_log_prefix(self), "cannot get rpop shm buffer: ", err)
        break
      elseif v == nil then
        break
      end

      local _, err = ws_send_func(v)
      if err then
        local _, err = self.SHM:lpush(self.SHM_KEY, v)
        ngx.log(ngx.WARN, get_log_prefix(self), "cannot putting back to shm buffer: ", err)
        break
      end
      sent = true

      ngx.log(ngx.DEBUG, get_log_prefix(self), "flush ", #v, " bytes to CP")
    end

    -- this is like a ping in case no other data is produced
    if not sent then
      ws_send_func(get_dummy_heartbeat_msg(self))
    end
  else
    ngx.log(ngx.DEBUG, get_log_prefix(self), "websocket is not ready yet, waiting for next try")
  end


  local len, err = self.SHM:llen(self.SHM_KEY)
  if err then
    ngx.log(ngx.WARN, _log_prefix, "cannot get length of shm buffer: ", err)
  elseif len > self.buffer_retry_size then
    ngx.log(ngx.WARN, _log_prefix, "cleaned up ", len - self.buffer_retry_size, " unflushed buffer")
    for _=0, len - self.buffer_retry_size do
      self.SHM:rpop(self.SHM_KEY)
    end
  end

  assert(ngx.timer.at(self.buffer_ttl, flush_cp, self))
end

local function start_ws_client(address, server_name)
  local uri = "wss://" .. address .. "/v1/ingest?node_id=" ..
    kong.node.get_id() .. "&node_hostname=" .. utils.get_hostname()

  assert(ngx.timer.at(0, clustering.communicate, uri, server_name, function(connected, send_func)
    if connected then
      ngx.log(ngx.DEBUG, _log_prefix, "telemetry websocket is connected")
      ws_send_func = send_func
    else
      ngx.log(ngx.DEBUG, _log_prefix, "telemetry websocket is disconnected")
      ws_send_func = nil
    end
  end))
end

local function check_address(address)
  local host, port
  local m, _ = ngx.re.match(address, [[([^:]+):(\d+)]])
  if m then
    host = m[1]
    port = tonumber(m[2])
  end

  if not host or not port then
    error("Malformed cluster endpoint address", 2)
  end
end

local function check_opts(self, opts)
  if not opts.message_type then
    return false, "'message_type' is missing"
  end

  if not opts.serve_ingest_func then
    return false, "'serve_ingest_func' is missing"
  end

  if not opts.shm then
    return false, "'SHM' is missing"
  end

  if not opts.shm_key then
    return false, "'SHM_KEY' is missing"
  end

  if not opts.type or (opts.type ~= self.TYPE.PRODUCER
    and opts.type ~= self.TYPE.CONSUMER) then
    return false, "'TYPE' is missing or is not supported"
  end

  return true
end

--
-- @param opts - configuration options
function _M:new(opts)
  local ok, err = check_opts(self, opts)
  if not ok then
    return nil, err
  end

  if opts.type == self.TYPE.PRODUCER then
    -- validate cluster endpoint address
    check_address(opts.cluster_endpoint)
  end

  local self = {
    -- Is it consumer or producer
    type = opts.type,
    cluster_endpoint = opts.cluster_endpoint,
    message_type = opts.message_type,
    message_type_version = opts.message_type_version or "v1",
    serve_ingest = opts.serve_ingest_func,
    serve_ingest_args = opts.serve_ingest_func_args,
    SHM = opts.shm,
    SHM_KEY = opts.shm_key,
    buffer = opts.buffer or new_tab(BUFFER_SIZE, 0),
    buffer_ttl = opts.buffer_ttl or 2,
    buffer_retry_size = opts.buffer_retry_size or 60,
  }
  setmetatable(self, mt)
  return self
end

function _M:register_for_messages()
  clustering.register_server_on_message(self.message_type, function(...)
    self:serve_ingest(...)
  end)
end

function _M:start_client(server_name)
  if ngx.worker.id() == 0 then
    start_ws_client(self.cluster_endpoint, server_name)

    assert(ngx.timer.at(self.buffer_ttl, flush_cp, self))
  end
  return true
end

function _M:send_message(typ, data)
  local buffer_idx = 1
  self.buffer[buffer_idx] = typ
  self.buffer[buffer_idx+1] = data

  local data = cjson_encode({
    type = self.message_type,
    -- TODO: msgid for re-transmit
    -- cjson decodes nil to lightuserdata null, this is unhandled
    -- in db strategies, to avoid introducing too much change we
    -- use mp_pack to wrap inner payloads
    data = mp_pack({
      self.message_type_version,
      self.message_type,
      self.buffer,
    }),
  })
  clear_tab(self.buffer)

  local _, err = self.SHM:lpush(self.SHM_KEY, data)
  if err then
    return false, err
  end

  return true
end

function _M:unpack_message(msg)
  local v, t, payload = unpack(mp_unpack(msg.data))
  if v ~= self.message_type_version or t ~= self.message_type then
    return nil, "ingest version or type doesn't match, expect version "
      .. self.message_type_version .." type "
      .. self.message_type .. ", got version " .. v .." type " .. t
  end
  return payload, nil
end

return _M
