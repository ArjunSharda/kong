local cjson = require "cjson"
local tx = require "pl/tablex"
local inspect = require "inspect"

local request = require "kong.enterprise_edition.utils".request

local fmt = string.format
local ngx_null = ngx.null
local md5 = ngx.md5
local hmac_sha1 = ngx.hmac_sha1
local to_hex = require "resty.string".to_hex

-- Somehow initializing this fails when kong runs on stream only. Something
-- missing on ngx.location. XXX: check back later
local template

-- XXX TODO:
-- make slack nicer
-- refactor http request into something useful

local _M = {}

local events = {}

-- Not sure if this is good enough. Holds references to callbacks by id so
-- we can properly unregister worker events
local references = {}

_M.enabled = function()
  return kong.configuration.databus_enabled
end

_M.crud = function(data)
  if data.operation == "delete" then
    _M.unregister(data.entity)
  elseif data.operation == "update" then
    _M.unregister(data.old_entity)
    _M.register(data.entity)
  elseif data.operation == "create" then
    _M.register(data.entity)
  end
end

_M.publish = function(source, event, opts)
  opts = opts or {}
  if not _M.enabled() then return end
  if not events[source] then events[source] = {} end
  events[source][event] = {
    description = opts.description,
    fields = opts.fields,
    unique = opts.unique,
  }
  return true
end

_M.register = function(entity)
  if not _M.enabled() then return end
  local callback = _M.callback(entity)
  local source = entity.source
  local event = entity.event ~= ngx_null and entity.event or nil

  references[entity.id] = callback

  return kong.worker_events.register(callback, source, event)
end

_M.unregister = function(entity)
  if not _M.enabled() then return end
  local callback = references[entity.id]
  local source = entity.source
  local event = entity.event ~= ngx_null and entity.event or nil

  -- XXX This good? maybe check if the unregister was succesful
  references[entity.id] = nil

  return kong.worker_events.unregister(callback, source, event)
end

_M.emit = function(source, event, data)
  if not _M.enabled() then return end
  return kong.worker_events.post_local(source, event, data)
end

_M.list = function()
  return events
end

-- Not to be used for security signing. This function is only used for
-- differentiating different data payloads for caching and deduplicating
-- purposes
_M.digest = function(data, opts)
  local opts = opts or {}
  local fields = opts.fields
  local data = fields and tx.intersection(data, tx.makeset(fields)) or data
  return md5(cjson.encode(data))
end

local function field_digest(source, event, data)
  local fields = events[source] and events[source][event] and
                 events[source][event].unique
  return _M.digest(data, { fields = fields })
end

-- XXX: hack to get asynchronous execution of callbacks. Check with thijs
-- about this.
local BatchQueue = require "kong.tools.batch_queue"

local process_callback = function(batch)
  local entry = batch[1]
  local ok, res = pcall(entry.callback, entry.data, entry.event, entry.source, entry.pid)
  if not ok then
    kong.log.err(res)
    return false, res
  end
  return res
end

local queue = BatchQueue.new(process_callback, {
  batch_max_size = 1
})

_M.callback = function(entity)
  local callback = _M.handlers[entity.handler](entity, entity.config)
  local wrap = function(data, event, source, pid)
    local ttl = entity.snooze ~= ngx_null and entity.snooze or nil
    local on_change = entity.on_change ~= ngx_null and entity.on_change or nil

    if ttl or on_change then
      -- kong:cache is used as a blacklist of events to not process:
      -- > on_change: only enqueue an event that has changed (looks different)
      -- > snooze: like an alarm clock, disable event for N seconds
      local cache_key = fmt("dbus:%s:%s:%s", entity.id, source, event)

      -- append digest of relevant fields in data to filter by same-ness
      if on_change then
        cache_key = cache_key .. ":" .. field_digest(source, event, data)
      end

      local _, _, hit_lvl = kong.cache:get(cache_key, nil, function(ttl)
        return true, nil, ttl
      end, ttl)

      -- either in L1 or L2, this event is to be ignored
      if hit_lvl ~= 3 then
        kong.log.warn("ignoring dbus event: ", cache_key)
        return
      end
    end

    local blob = {
      callback = callback,
      data = data,
      event = event,
      source = source,
      pid = pid,
    }

    queue:add(blob)
  end

  return wrap
end


local function sign_body(secret)
  return function(body)
    return "sha1", to_hex(hmac_sha1(secret, body))
  end
end


_M.handlers = {
  -- Simple and opinionated webhook. No bells and whistles, 0 config
  --    > method POST
  --    > content-type: application/json
  --    > body: json(data)
  --    > arbitrary headers
  --    > can be signed
  webhook = function(entity, config)
    return function(data, event, source, pid)
      local headers = config.headers ~= ngx_null and config.headers or {}
      local method = "POST"

      headers['content-type'] = "application/json"
      data.event = event
      data.source = source

      local body = cjson.encode(data)

      kong.log.debug("webhook event data: ", inspect({data, event, source, pid}))
      local res, err = request(config.url, {
        method = method,
        body = body,
        sign_with = config.secret and config.secret ~= ngx_null and sign_body(config.secret),
        headers = headers
      })
      kong.log.debug("response: ", inspect({res and res.status or nil, err}))
      return not err
    end
  end,

  ["webhook-custom"] = function(entity, config)

    -- Somehow initializing this fails when kong runs on stream only. Something
    -- missing on ngx.location. XXX: check back later
    if not template then
      template = require "resty.template"
    end

    return function(data, event, source, pid)
      local payload, body, headers
      local method = config.method

      data.event = event
      data.source = source

      if config.payload and config.payload ~= ngx_null then
        if config.payload_format then
          payload = {}
          for k, v in pairs(config.payload) do
            payload[k] = template.compile(v)(data)
          end
        else
          payload = config.payload
        end
      end

      if config.body and config.body ~= ngx_null then
        if config.body_format then
          body = template.compile(config.body)(data)
        else
          body = config.body
        end
      end

      if config.headers and config.headers ~= ngx_null then
        if config.headers_format then
          headers = {}
          for k, v in pairs(config.headers) do
            headers[k] = template.compile(v)(data)
          end
        else
          headers = config.headers
        end
      end

      kong.log.debug("webhook event data: ", inspect({data, event, source, pid}))
      local res, err = request(config.url, {
        method = method,
        data = payload,
        body = body,
        sign_with = config.secret and config.secret ~= ngx_null and sign_body(config.secret),
        headers = headers
      })
      kong.log.debug("response: ", inspect({res and res.status or nil, err}))
      return not err
    end
  end,

  -- This would be a specialized helper easier to configure than a webhook
  -- even though slack would use a webhook
  slack = function(entity, config)
    return function(data, event, source, pid)
      kong.log.debug("slack event data: ", inspect({data, event, source, pid}))
      kong.log.debug("slack callback not implemented")
      return true
    end
  end,

  log = function(entity, config)
    return function(data, event, source, pid)
      kong.log.notice("log callback ", inspect({event, source, data, pid}))
      return true
    end
  end,

  lambda = function(entity, config)
    local functions = {}

    -- limit execution context
    --local helper_ctx = {
    --  require = require,
    --  type = type,
    --  print = print,
    --  pairs = pairs,
    --  ipairs = ipairs,
    --  inspect = inspect,
    --  request = request,
    --  kong = kong,
    --  ngx = ngx,
    --  -- ... anything else useful ?
    --}
    -- or allow _anything_
    local helper_ctx = _G

    local chunk_name = "dbus:" .. entity.id

    for i, fn_str in ipairs(config.functions or {}) do
      -- each function has its own context. We could let them share context
      -- by not defining fn_ctx and just passing helper_ctx
      local fn_ctx = {}
      setmetatable(fn_ctx, { __index = helper_ctx })
      -- t -> only text chunks
      local fn = load(fn_str, chunk_name .. ":" .. i, "t", fn_ctx)     -- load
      local _, actual_fn = pcall(fn)
      table.insert(functions, actual_fn)
    end

    return function(data, event, source, pid)
      -- reduce on functions with data
      local err
      for _, fn in ipairs(functions) do
        data, err = fn(data, event, source, pid)
      end
      return not err
    end
  end,
}

-- accessors to ease unit testing
_M.events = events
_M.references = references
_M.queue = queue

return _M
