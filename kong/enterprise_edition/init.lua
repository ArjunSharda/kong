local log        = require "kong.cmd.utils.log"
local meta       = require "kong.enterprise_edition.meta"
local pl_file    = require "pl.file"
local pl_utils   = require "pl.utils"
local pl_path    = require "pl.path"
local constants  = require "kong.constants"
local workspaces = require "kong.workspaces"
local feature_flags   = require "kong.enterprise_edition.feature_flags"
local license_helpers = require "kong.enterprise_edition.license_helpers"
local event_hooks = require "kong.enterprise_edition.event_hooks"
local balancer  = require "kong.runloop.balancer"
local rbac = require "kong.rbac"
local hooks = require "kong.hooks"
local ee_api = require "kong.enterprise_edition.api_helpers"
local utils = require "kong.tools.utils"
local app_helpers = require "lapis.application"
local api_helpers = require "kong.api.api_helpers"
local tracing = require "kong.tracing"
local counters = require "kong.workspaces.counters"
local workspace_config = require "kong.portal.workspace_config"


local kong = kong
local ws_constants  = constants.WORKSPACE_CONFIG
local _M = {}


_M.handlers = {
  init = {
    after = function()
      rbac.register_dao_hooks(kong.db)
      counters.register_dao_hooks()

      hooks.register_hook("api:init:pre", function(app)
        app:before_filter(ee_api.before_filter)

        for _, v in ipairs({"vitals", "oas_config", "license",
                            "entities", "keyring"}) do

          local routes = require("kong.api.routes." .. v)
          api_helpers.attach_routes(app, routes)
        end

        -- attach `/:workspace/kong`, which replicates `/`
        local slash_handler = require "kong.api.routes.kong"["/"]
        app:match("ws_root" .. "/", "/:workspace_name/kong",
        app_helpers.respond_to(slash_handler))

        return true
      end)

      hooks.register_hook("api:init:post", function(app, routes)
        for _, k in ipairs({"rbac", "audit"}) do
          local loaded, mod = utils.load_module_if_exists("kong.api.routes.".. k)
          if loaded then
            ngx.log(ngx.DEBUG, "Loading API endpoints for module: ", k)
            if api_helpers.is_new_db_routes(mod) then
              api_helpers.attach_new_db_routes(app, mod)
            else
              api_helpers.attach_routes(app, mod)
            end

          else
            ngx.log(ngx.DEBUG, "No API endpoints loaded for module: ", k)
          end
        end

        ee_api.splatify_entity_route("files", routes)

        return true
      end)

      local function prepend_workspace_prefix(app, route_path, methods)
        if route_path ~= "/" then
          app:match("workspace_" .. route_path, "/:workspace_name" .. route_path,
          app_helpers.respond_to(methods))
        end

        return true
      end

      hooks.register_hook("api:helpers:attach_routes", prepend_workspace_prefix)
      hooks.register_hook("api:helpers:attach_new_db_routes", prepend_workspace_prefix)

      hooks.register_hook("balancer:get_peer:pre", function(target_host)
        return tracing.trace("balancer.getPeer", { qname = target_host })
      end)

      hooks.register_hook("balancer:get_peer:post", function(trace)
        trace:finish()
      end)

      hooks.register_hook("balancer:to_ip:pre", function(target_host)
        return tracing.trace("balancer.toip", { qname = target_host })
      end)

      hooks.register_hook("balancer:to-ip:post", function(trace)
        trace:finish()
      end)

    end
  },
  init_worker = {
    after = function(ctx)
      license_helpers.report_expired_license()

      -- register event_hooks hooks
      if event_hooks.enabled() then
        local dao_adapter = function(data)
          return {
            entity = data.entity,
            old_entity = data.old_entity,
            schema = data.schema and data.schema.name,
            operation = data.operation,
          }
        end
        -- publish all kong events
        local operations = { "create", "update", "delete" }
        for _, op in ipairs(operations) do
          event_hooks.publish("dao:crud", op, {
            fields = { "operation", "entity", "old_entity", "schema" },
            adapter = dao_adapter,
          })
        end
        for name, _ in pairs(kong.db.daos) do
          event_hooks.publish("crud", name, {
            fields = { "operation", "entity", "old_entity", "schema" },
            adapter = dao_adapter,
          })
          for _, op in ipairs(operations) do
            event_hooks.publish("crud", name .. ":" .. op, {
              fields = { "operation", "entity", "old_entity", "schema" },
              adapter = dao_adapter,
            })
          end
        end

        kong.worker_events.register(function(data, event, source, pid)
          event_hooks.emit(source, event, dao_adapter(data))
        end, "crud")

        kong.worker_events.register(function(data, event, source, pid)
          event_hooks.emit(source, event, dao_adapter(data))
        end, "dao:crud")

        -- register a callback to trigger an event_hook balanacer health
        -- event
        balancer.subscribe_to_healthcheck_events(function(upstream_id, ip, port, hostname, health)
          event_hooks.emit("balancer", "health", {
            upstream_id = upstream_id,
            ip = ip,
            port = port,
            hostname = hostname,
            health = health,
          })
        end)

        event_hooks.publish("balancer", "health", {
          fields = { "upstream_id", "ip", "port", "hostname", "health" },
        })

        -- XXX not so sure this timer is good? the idea is to not hog kong
        -- on startup for this secondary feature
        ngx.timer.at(0, function()
          for entity, err in kong.db.event_hooks:each(1000) do
            if err then
              kong.log.err(err)
            else
              event_hooks.register(entity)
            end
          end
        end)
      end
    end,
  },
  header_filter = {
    after = function(ctx)
      if not ctx.is_internal then
        kong.vitals:log_upstream_latency(ctx.KONG_WAITING_TIME)
      end
    end
  },
  log = {
    after = function(ctx, status)
      tracing.flush()

      if not ctx.is_internal then
        kong.vitals:log_latency(ctx.KONG_PROXY_LATENCY)
        kong.vitals:log_request(ctx)
        kong.sales_counters:log_request()
        kong.vitals:log_phase_after_plugins(ctx, status)
      end
    end
  }
}


function _M.feature_flags_init(config)
  if config and config.feature_conf_path and config.feature_conf_path ~= "" then
    local _, err = feature_flags.init(config.feature_conf_path)
    if err then
      return err
    end
  end
end

_M.read_license_info = license_helpers.read_license_info

local function write_kconfig(configs, filename)
  local kconfig_str = "window.K_CONFIG = {\n"
  for config, value in pairs(configs) do
    kconfig_str = kconfig_str .. "  '" .. config .. "': '" .. value .. "',\n"
  end

  -- remove trailing comma
  kconfig_str = kconfig_str:sub(1, -3)

  if not pl_file.write(filename, kconfig_str .. "\n}\n") then
    log.warn("Could not write file ".. filename .. ". Ensure that the Kong " ..
             "CLI user has permissions to write to this directory")
  end
end


local function prepare_interface(usr_path, interface_dir, interface_conf_dir, interface_env, kong_config)
  local usr_interface_path = usr_path .. "/" .. interface_dir
  local interface_path = kong_config.prefix .. "/" .. interface_dir
  local interface_conf_path = kong_config.prefix .. "/" .. interface_conf_dir
  local compile_env = interface_env
  local config_filename = interface_conf_path .. "/kconfig.js"

  if not pl_path.exists(interface_conf_path) then
      if not pl_path.mkdir(interface_conf_path) then
        log.warn("Could not create directory " .. interface_conf_path .. ". " ..
                 "Ensure that the Kong CLI user has permissions to create " ..
                 "this directory.")
      end
  end

  -- if the interface directory is not exist in custom prefix directory
  -- try symlinking to the default prefix location
  -- ensure user can access the interface appliation
  if not pl_path.exists(interface_path)
     and pl_path.exists(usr_interface_path) then

    local ln_cmd = "ln -s " .. usr_interface_path .. " " .. interface_path
    local ok, _, _, err_t = pl_utils.executeex(ln_cmd)

    if not ok then
      log.warn(err_t)
    end
  end

  write_kconfig(compile_env, config_filename)
end
_M.prepare_interface = prepare_interface

-- return first listener matching filters
local function select_listener(listeners, filters)
  for _, listener in ipairs(listeners) do
    local match = true
    for filter, value in pairs(filters) do
      if listener[filter] ~= value then
        match = false
      end
    end
    if match then
      return listener
    end
  end
end


local function prepare_variable(variable)
  if variable == nil then
    return ""
  end

  return tostring(variable)
end


function _M.prepare_admin(kong_config)
  local gui_listen = select_listener(kong_config.admin_gui_listeners, {ssl = false})
  local gui_port = gui_listen and gui_listen.port
  local gui_ssl_listen = select_listener(kong_config.admin_gui_listeners, {ssl = true})
  local gui_ssl_port = gui_ssl_listen and gui_ssl_listen.port

  local api_url
  local api_listen
  local api_port
  local api_ssl_listen
  local api_ssl_port

  -- only access the admin API on the proxy if auth is enabled
  api_listen = select_listener(kong_config.admin_listeners, {ssl = false})
  api_port = api_listen and api_listen.port
  api_ssl_listen = select_listener(kong_config.admin_listeners, {ssl = true})
  api_ssl_port = api_ssl_listen and api_ssl_listen.port
  -- TODO: stop using this property, and introduce admin_api_url so that
  -- api_url always includes the protocol
  api_url = kong_config.admin_api_uri

  -- we will consider rbac to be on if it is set to "both" or "on",
  -- because we don't currently support entity-level
  local rbac_enforced = kong_config.rbac == "both" or kong_config.rbac == "on"

  return prepare_interface("/usr/local/kong", "gui", "gui_config", {
    ADMIN_GUI_AUTH = prepare_variable(kong_config.admin_gui_auth),
    ADMIN_GUI_URL = prepare_variable(kong_config.admin_gui_url),
    ADMIN_GUI_PORT = prepare_variable(gui_port),
    ADMIN_GUI_SSL_PORT = prepare_variable(gui_ssl_port),
    ADMIN_API_URL = prepare_variable(api_url),
    ADMIN_API_PORT = prepare_variable(api_port),
    ADMIN_API_SSL_PORT = prepare_variable(api_ssl_port),
    RBAC = prepare_variable(kong_config.rbac),
    RBAC_ENFORCED = prepare_variable(rbac_enforced),
    RBAC_HEADER = prepare_variable(kong_config.rbac_auth_header),
    RBAC_USER_HEADER = prepare_variable(kong_config.admin_gui_auth_header),
    KONG_VERSION = prepare_variable(meta.versions.package),
    FEATURE_FLAGS = prepare_variable(kong_config.admin_gui_flags),
    PORTAL = prepare_variable(kong_config.portal),
    PORTAL_GUI_PROTOCOL = prepare_variable(kong_config.portal_gui_protocol),
    PORTAL_GUI_HOST = prepare_variable(kong_config.portal_gui_host),
    PORTAL_GUI_USE_SUBDOMAINS = prepare_variable(kong_config.portal_gui_use_subdomains),
    ANONYMOUS_REPORTS = prepare_variable(kong_config.anonymous_reports),
  }, kong_config)
end


function _M.prepare_portal(self, kong_config)
  local workspace = workspaces.get_workspace()
  local is_authenticated = self.developer ~= nil

  local portal_gui_listener = select_listener(kong_config.portal_gui_listeners,
                                              {ssl = false})
  local portal_gui_ssl_listener = select_listener(kong_config.portal_gui_listeners,
                                                  {ssl = true})
  local portal_gui_port = portal_gui_listener and portal_gui_listener.port
  local portal_gui_ssl_port = portal_gui_ssl_listener and portal_gui_ssl_listener.port
  local portal_api_listener = select_listener(kong_config.portal_api_listeners,
                                         {ssl = false})
  local portal_api_ssl_listener = select_listener(kong_config.portal_api_listeners,
                                             {ssl = true})
  local portal_api_port = portal_api_listener and portal_api_listener.port
  local portal_api_ssl_port = portal_api_ssl_listener and portal_api_ssl_listener.port

  local rbac_enforced = kong_config.rbac == "both" or kong_config.rbac == "on"

  local portal_gui_url = workspace_config.build_ws_portal_gui_url(kong_config, workspace)
  local portal_auth = workspace_config.retrieve(ws_constants.PORTAL_AUTH, workspace)

  local opts = { explicitly_ws = true }
  local portal_developer_meta_fields = workspace_config.retrieve(
                            ws_constants.PORTAL_DEVELOPER_META_FIELDS,
                            workspace, opts) or '[]'

  return {
    PORTAL_API_URL = prepare_variable(kong_config.portal_api_url),
    PORTAL_AUTH = prepare_variable(portal_auth),
    PORTAL_API_PORT = prepare_variable(portal_api_port),
    PORTAL_API_SSL_PORT = prepare_variable(portal_api_ssl_port),
    PORTAL_GUI_URL = prepare_variable(portal_gui_url),
    PORTAL_GUI_PORT = prepare_variable(portal_gui_port),
    PORTAL_GUI_SSL_PORT = prepare_variable(portal_gui_ssl_port),
    PORTAL_IS_AUTHENTICATED = prepare_variable(is_authenticated),
    PORTAL_GUI_USE_SUBDOMAINS = prepare_variable(kong_config.portal_gui_use_subdomains),
    PORTAL_DEVELOPER_META_FIELDS = prepare_variable(portal_developer_meta_fields),
    RBAC_ENFORCED = prepare_variable(rbac_enforced),
    RBAC_HEADER = prepare_variable(kong_config.rbac_auth_header),
    KONG_VERSION = prepare_variable(meta.versions.package),
    WORKSPACE = prepare_variable(workspace.name)
  }
end

return _M