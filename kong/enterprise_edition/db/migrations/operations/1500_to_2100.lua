-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

-- Helper module for 1500_to_2100 Enterprise migration operations.
--
-- Operations are versioned and specific to a migration so they remain
-- fixed in time and are not modified for use in future migrations.
--
-- If you want to reuse these operations in a future migration,
-- copy the functions over to a new versioned module.
local ce_operations = require "kong.db.migrations.operations.200_to_210"
local log           = require "kong.cmd.utils.log"



local concat = table.concat
local fmt = string.format


local function render(template, keys)
  return (template:gsub("$%(([A-Z_]+)%)", keys))
end


local function postgres_run_query_in_transaction(connector, query)
  assert(connector:query(concat({ "BEGIN", query, "COMMIT"}, ";")))
end


local function postgres_list_tables(connector)
  local tables = {}

  local sql = fmt([[
    SELECT table_name
      FROM information_schema.tables
     WHERE table_schema='%s'
  ]], connector.config.schema)
  local rows, err = connector:query(sql)
  if err then
    return nil, err
  end

  for _, v in ipairs(rows) do
    local _, vv = next(v)
    tables[vv] = true
  end

  return tables
end

local function postgres_remove_prefixes_code(entity, code)
  if #entity.uniques > 0 then
    local fields = {}
    for _, f in ipairs(entity.uniques) do
      table.insert(fields, f .. " = regexp_replace(" .. f .. ", '^(' || (SELECT string_agg(name, '|') FROM workspaces) ||'):', '')")
    end

    table.insert(code,
      render([[
        UPDATE $(TABLE) SET $(FIELDS);
      ]], {
        TABLE = entity.name,
        FIELDS = table.concat(fields, ", "),
      })
    )
  end
end

local function postgres_workspaceable_code(entity, code)
  table.insert(code,
    render([[

      -- fixing up workspaceable rows for $(TABLE)

      UPDATE $(TABLE)
      SET ws_id = we.workspace_id
      FROM workspace_entities we
      WHERE entity_type='$(TABLE)'
        AND unique_field_name='$(PK)'
        AND unique_field_value=$(TABLE).$(PK)::text;
    ]], {
      TABLE = entity.name,
      PK = entity.primary_key,
    })
  )
end

local function cassandra_list_tables(connector)
  local coordinator = connector:connect_migrations()
  local tables = {}

  local cql = fmt([[
    SELECT table_name
      FROM system_schema.tables
     WHERE keyspace_name='%s';
  ]], connector.keyspace)
  for rows, err in coordinator:iterate(cql) do
    if err then
      return nil, err
    end

    for _, row in ipairs(rows) do
      tables[row.table_name] = true
    end
  end

  return tables
end


local function cassandra_foreach_row(connector, table_name, f)
  local coordinator = connector:connect_migrations()

  for rows, err in coordinator:iterate("SELECT * FROM " .. table_name,
                                       nil,
                                       { keyspace = connector.keyspace }) do
    if err then
      return nil, err
    end

    for _, row in ipairs(rows) do
      f(row)
    end
  end
end


local memo_prefix_fixups
local function cassandra_get_prefix_fixups_table(connector)
  -- memoize results
  if memo_prefix_fixups then
    return memo_prefix_fixups
  end

  memo_prefix_fixups = {}
  cassandra_foreach_row(connector, "workspaces", function(e)
    memo_prefix_fixups[e.name .. ":"] = e.id .. ":"
  end)

  return memo_prefix_fixups
end


local memo_is_partitioned = {}
local function cassandra_table_is_partitioned(connector, table_name)
  -- memoize results
  if memo_is_partitioned[table_name] ~= nil then
    return memo_is_partitioned[table_name]
  end

  -- Assume a release version number of 3 & greater will use the same schema.
  local cql
  if connector.major_version >= 3 then
    cql = [[
      SELECT * FROM system_schema.columns
      WHERE keyspace_name = '$(KEYSPACE)'
      AND table_name = '$(TABLE)'
      AND column_name = 'partition';
    ]]
  else
    cql = [[
      SELECT * FROM system.schema_columns
      WHERE keyspace_name = '$(KEYSPACE)'
      AND columnfamily_name = '$(TABLE)'
      AND column_name = 'partition';
    ]]
  end

  cql = render(cql, {
    KEYSPACE = connector.keyspace,
    TABLE = table_name,
  })

  local rows, err = connector:query(cql, {}, nil, "read")
  if err then
    return nil, err
  end

  -- Assume a release version number of 3 & greater will use the same schema.
  if connector.major_version >= 3 then
    return rows[1] and rows[1].kind == "partition_key"
  end

  memo_is_partitioned[table_name] = not not rows[1]
  return memo_is_partitioned[table_name]
end

local function cassandra_ws_fixup_rows(_, connector, entity)
  local code = {}

  local ws_prefix_fixups = cassandra_get_prefix_fixups_table(connector)
  local tables = cassandra_list_tables(connector)

  cassandra_foreach_row(connector, entity.name, function(row)
    local ws_name, ws_id
    local fields = {}

    for _, f in ipairs(entity.uniques) do
      local value = row[f]
      if row[f] then
        local colon_pos = row[f]:find(":")
        if colon_pos then
          ws_name = ws_name or row[f]:sub(1, colon_pos)
          value = string.gsub(row[f], "^[^:]+:", ws_prefix_fixups)
        end

        table.insert(fields, fmt("%s = '%s'", f, value))
      end
    end

    -- if consumer entity then match it's ws_id with consumers ws_id
    if row['consumer_id'] then
      ws_id = connector:query(render([[
                SELECT ws_id FROM $(KEYSPACE).consumers
                WHERE id = '$(ID)';
              ]], {
        KEYSPACE = connector.keyspace,
        ID = row['consumer_id'],
      }))
    end

    if not ws_name and tables.workspace_entities then
      -- assumes that primary keys are 'id',
      -- which is currently true for all workspaceable entities
      ws_name = ws_name or connector:query(render([[
              SELECT workspace_name FROM $(KEYSPACE).workspace_entities
              WHERE entity_id = '$(ID)' LIMIT 1 ALLOW FILTERING;
            ]], {
        KEYSPACE = connector.keyspace,
        ID = row[entity.primary_key],
      }))

      ws_name = ws_name and
        ws_name[1] and
        ws_name[1].workspace_name and
        ws_name[1].workspace_name .. ":"
    end
    if not ws_name or not ws_prefix_fixups[ws_name] then
      -- data is already adjusted, bail out
      return
    end

    table.insert(fields, "ws_id = " .. (ws_id and ws_id or ws_prefix_fixups[ws_name]:sub(1, -2)))

    table.insert(code, render([[
            UPDATE $(KEYSPACE).$(TABLE) SET $(FIELDS) WHERE id = $(ID) $(PARTITION);
          ]], {
      KEYSPACE = connector.keyspace,
      TABLE = entity.name,
      FIELDS = table.concat(fields, ", "),
      ID = row[entity.primary_key],
      PARTITION = cassandra_table_is_partitioned(connector, entity.name)
        and fmt([[ AND partition = '%s']], entity.name)
        or "",
    }))
  end)

  connector:query(table.concat(code, ";\n"))
end
--------------------------------------------------------------------------------
-- Postgres operations for Workspace data migration
--------------------------------------------------------------------------------


local postgres = {

  up = {
  },

  teardown = {

    ----------------------------------------------------------------------------
    -- Set `ws_id` fields based on values from `workspace_entities`,
    -- and remove prefixes from unique values.
    ws_fixup_workspaceable_rows = function(_, connector, entity)
      log.debug("ws_fixup_workspaceable_rows: "..  entity.name)

      local code = {}

      -- populate ws_id:
      -- XXX EE shared entities will pick one of the workspaces
      -- they're in.
      local existing_tables, err = postgres_list_tables(connector)
      if err then
        ngx.log(ngx.ERR, [[err: ]], type(err)=='string' and err or type(err))
        return nil, err
      end

      if existing_tables.workspace_entities then
        postgres_workspaceable_code(entity, code)
      end

      postgres_remove_prefixes_code(entity, code)

      postgres_run_query_in_transaction(connector, table.concat(code))
      log.debug("ws_fixup_workspaceable_rows: "..  entity.name .. " DONE")
    end,

    -- Used to assign the ws_id for plugins that depend on a consumer. Those
    -- plugin entities end up with a DB constraint that requires the consumer
    -- and any plugin entity data to exist in the same workspace. But in the
    -- case of a shared consumer it is possible that the ws_id picked for that
    -- consumer does not match the ws_id for the associated plugin entity from
    -- the data in the workspace_entities table.
    --
    -- To avoid hitting this constraint we set the ws_id for each plugin entity
    -- based on the associated consumer, instead of from the workspace_entities
    -- table.
    --
    -- This function does not affect data on the `plugins` table but on tables
    -- created by each installed Kong Plugin.
    ws_fixup_consumer_plugin_rows = function(_, connector, entity)
      log.debug("ws_fixup_consumer_plugin_rows: "..  entity.name)

      local code = {}

      -- customers can be in the middle of a failed 1.5 -> 2.1 migration with no
      -- way to create the ws_migrations_backup table. In this case, proceed
      -- with the migration to fix the customer.
      local existing_tables, err = postgres_list_tables(connector)
      if err then
        ngx.log(ngx.ERR, [[err: ]], type(err)=='string' and err or type(err))
        return nil, err
      end

      if existing_tables.ws_migrations_backup then
        for _, unique in ipairs(entity.uniques) do
          table.insert(code,
            render([[
              INSERT INTO ws_migrations_backup (entity_type, entity_id, unique_field_name, unique_field_value)
              SELECT '$(TABLE)', $(TABLE).$(PK)::text, '$(UNIQUE)', $(TABLE).$(UNIQUE)
              FROM $(TABLE);
            ]], {
              TABLE = entity.name,
              PK = entity.primary_key,
              UNIQUE = unique
            })
          )
        end
      end

      local consumer_plugin = false
      for _, fk in ipairs(entity.fks) do
        if fk.reference == "consumers" then
          consumer_plugin = true
          break
        end
      end
      if consumer_plugin then
        table.insert(code,
          render([[
            UPDATE $(TABLE)
            SET ws_id = c.ws_id
            FROM consumers c
            WHERE $(TABLE).consumer_id = c.id;
          ]], {
            TABLE = entity.name
          })
        )
      else
        -- If this is not a consumer based plugin, fall back to existing
        -- behavior for setting ws_id from workspace_entities table.
        if existing_tables.workspace_entities then
          postgres_workspaceable_code(entity, code)
        end
      end

      postgres_remove_prefixes_code(entity, code)

      postgres_run_query_in_transaction(connector, table.concat(code))
      log.debug("ws_fixup_consumer_plugin_rows: "..  entity.name .. " DONE")
    end,

    ws_clean_kong_admin_rbac_user = function(_, connector)
      connector:query([[
        UPDATE rbac_users
           SET name = 'kong_admin'
         WHERE name = 'default:kong_admin';
      ]])
    end,

    ws_set_default_ws_for_admin_entities = function(_, connector)
      local code = {}
      local entities = { "rbac_user" }

      for _, e in ipairs(entities) do
        table.insert(code,
          render([[

            -- assign admin linked $(TABLE)' ws_id to default ws id

            update $(TABLE)
            set ws_id = (select id from workspaces where name='default')
            where id in (select $(COLUMN) from admins);
          ]], {
            TABLE = e .. "s",
            COLUMN = e .. "_id",
          })
        )
      end

      postgres_run_query_in_transaction(connector, table.concat(code))
    end,

    drop_run_on = function(_, connector)
      connector:query([[
        DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "plugins" DROP COLUMN "run_on";
        EXCEPTION WHEN UNDEFINED_COLUMN THEN
          -- Do nothing, accept existing state
        END;
        $$;
      ]])
    end,

    has_workspace_entities = function(_, connector)
      return connector:query([[
        SELECT * FROM pg_catalog.pg_tables WHERE tablename='workspace_entities';
      ]])
    end,

  },

}


--------------------------------------------------------------------------------
-- Cassandra operations for Workspace data migration
--------------------------------------------------------------------------------


local cassandra = {

  up = {
  },

  teardown = {

    ----------------------------------------------------------------------------
    -- Set `ws_id` fields based on values from `workspace_entities`.
    ws_fixup_workspaceable_rows = function(_, connector, entity)
      cassandra_ws_fixup_rows(_, connector, entity)
    end,

    ws_fixup_consumer_plugin_rows = function(_, connector, entity)
      cassandra_ws_fixup_rows(_, connector, entity)
    end,

    ws_clean_kong_admin_rbac_user = function(_, connector)
      local coordinator = connector:connect_migrations()

      local cql = render([[
        SELECT *
          FROM $(KEYSPACE).workspace_entities
         WHERE unique_field_value = 'kong_admin'
      ]], {
        KEYSPACE = connector.keyspace,
      })

      for rows, err in coordinator:iterate(cql) do
        if err then
          return nil, err
        end

        for _, row in ipairs(rows) do
          if row.entity_type == "rbac_users" then
            connector:query(render([[
              UPDATE $(KEYSPACE).rbac_users
                 SET name = 'kong_admin'
               WHERE id = $(ID);
            ]], {
              KEYSPACE = connector.keyspace,
              ID = row.entity_id,
            }))
          end
        end
      end
    end,

    ws_set_default_ws_for_admin_entities = function(_, connector)
      local coordinator = connector:connect_migrations()
      local entities = { "rbac_user" }

      local default_ws, err = connector:query(render([[
        SELECT id FROM $(KEYSPACE).workspaces
        WHERE name = 'default';
      ]], {
        KEYSPACE = connector.keyspace,
      }))

      if err then
        return nil, err
      end

      -- The core 200_to_210.lua opteration inserts
      -- `default` ws for cassandra regardless,
      -- so use the 1st item as default ws.
      local default_ws_id = default_ws and default_ws[1].id

      for _, e in ipairs(entities) do
        local column_name = e .. "_id"
        local cql = render([[
          SELECT * FROM $(KEYSPACE).admins;
        ]], {
          KEYSPACE = connector.keyspace,
        })

        for rows, err in coordinator:iterate(cql) do
          if err then
            return nil, err
          end

          for _, row in ipairs(rows) do
            connector:query(render([[
              update $(KEYSPACE).$(TABLE)
              set ws_id = $(WS_ID)
              where id = $(ID);
            ]], {
              KEYSPACE = connector.keyspace,
              TABLE = e .. "s",
              WS_ID = default_ws_id,
              ID = row[column_name],
            }))
          end
        end
      end
    end,

    drop_run_on = function(_, connector)
      -- no need to drop the actual row from the database
      -- (this operation is not reentrant in Cassandra)
      --[===[
      assert(connector:query([[
        ALTER TABLE plugins DROP run_on;
      ]]))
      ]===]
    end,

    has_workspace_entities = function(_, connector)
      return connector:query(render([[
        SELECT table_name FROM system_schema.tables
        WHERE keyspace_name='$(KEYSPACE)'
          AND table_name='workspace_entities';
      ]], {
        KEYSPACE = connector.keyspace,
      }))
    end,

  },

}


--------------------------------------------------------------------------------
-- Higher-level operations for Workspace data migration
--------------------------------------------------------------------------------


local function ws_adjust_data(ops, connector, entities)
  for _, entity in ipairs(entities) do
    log.debug("adjusting data for: " .. entity.name)
    ops.ws_fixup_workspaceable_rows(ops, connector, entity)
    log.debug("adjusting data for: " .. entity.name .. " ...DONE")
  end
end


postgres.teardown.ws_adjust_data = ws_adjust_data
cassandra.teardown.ws_adjust_data = ws_adjust_data


local function ws_migrate_plugin(plugin_entities)

  local function ws_migration_teardown(ops)
    return function(connector)
      for _, entity in ipairs(plugin_entities) do
        ops.ws_fixup_consumer_plugin_rows(ops, connector, entity)
      end
    end
  end

  return {
    postgres = {
      up = "",
      teardown = ws_migration_teardown(postgres.teardown),
    },

    cassandra = {
      up = "",
      teardown = ws_migration_teardown(cassandra.teardown),
    },
  }
end


--------------------------------------------------------------------------------


local ee_operations = {
  postgres = postgres,
  cassandra = cassandra,
  ws_migrate_plugin = ws_migrate_plugin,
  utils = {
    render = render,
    cassandra_table_is_partitioned = cassandra_table_is_partitioned,
    postgres_has_workspace_entities = postgres.teardown.has_workspace_entities,
    cassandra_has_workspace_entities = cassandra.teardown.has_workspace_entities,
  },
}


-- merge ce_operations into ee_operations table
for db, stages in pairs(ce_operations) do
  if type(stages) == "table" then
    for stage, ops in pairs(stages) do
      for name, fn in pairs(ops) do
        if not ee_operations[db][stage][name] then
          ee_operations[db][stage][name] = fn
        end
      end
    end
  end
end


return ee_operations