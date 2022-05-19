-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local kong = kong
local utils = require "kong.tools.utils"


local function _select_consumer_group(consumer_group_pk)
  if not utils.is_valid_uuid(consumer_group_pk) then
    return kong.db.consumer_groups:select_by_name(consumer_group_pk)
  end
  return kong.db.consumer_groups:select({ id=consumer_group_pk })
end

local function get_consumer_group(consumer_group_pk)
  local cache_key = kong.db.consumer_groups:cache_key(consumer_group_pk)
  return kong.cache:get(cache_key, nil, _select_consumer_group,consumer_group_pk)
end

local function _find_consumer_group_config(consumer_group_pk, plugin_name)
    for row, err in kong.db.consumer_group_plugins:each() do
      if row.consumer_group.id == consumer_group_pk then
        if err then
          kong.log.err(err)
          return nil, err
        end
        if row.consumer_group.id == consumer_group_pk and
          row.name == plugin_name then
            return row
        end
      end
    end
    return nil, "could not find the configuration"
  end


local function get_consumer_group_config(consumer_group_pk, plugin_name)
  local cache_key = kong.db.consumer_group_plugins:cache_key(consumer_group_pk, plugin_name)
  return kong.cache:get(cache_key, nil, _find_consumer_group_config, consumer_group_pk, plugin_name)
end

local function get_consumers_in_group(consumer_group_pk)
  local consumers = {}
  local len = 0
  for row, err in kong.db.consumer_group_consumers:each_for_consumer_group({ id = consumer_group_pk }) do
    len = len + 1
    consumers[len] = kong.db.consumers:select(row.consumer)
    if err then
      return nil, err
    end
  end
  if len == 0 then
    return nil
  end
  return consumers
end


local function _find_consumer_in_group(cache_key)
  return kong.db.consumer_group_consumers:select_by_cache_key(cache_key)
end

local function is_consumer_in_group(consumer_pk, consumer_group_pk)
  local cache_key = kong.db.consumer_group_consumers:cache_key(consumer_group_pk, consumer_pk)
  local relation, err = kong.cache:get(cache_key, nil, _find_consumer_in_group, cache_key)
  if relation then
    return true
  end
  return false, err
end

local function delete_consumer_in_group(consumer_pk, consumer_group_pk)
  if is_consumer_in_group(consumer_pk, consumer_group_pk) then
    kong.db.consumer_group_consumers:delete(
      {
        consumer_group = {id = consumer_group_pk},
        consumer = { id = consumer_pk,},
      }
    )
    return true
  else
    return false
  end
end

local function get_plugins_in_group(consumer_group_pk)
  local plugins = {}
  local len = 0
  for row, err in kong.db.consumer_group_plugins:each_for_consumer_group({ id = consumer_group_pk }) do
    len = len + 1
    plugins[len] = row
    if err then
      return nil, err
    end
  end
  if len == 0 then
    return nil
  end
  return plugins
end

local function select_by_username_or_id(db, key)
  local entity
  if not utils.is_valid_uuid(key) then
    entity = db:select_by_username(key)
  else
    entity = db:select({ id = key })
  end
  return entity
end

local function get_groups_by_consumer(consumer_pk)
  local groups = {}
  local len = 0
  for row, err in kong.db.consumer_group_consumers:each_for_consumer({ id = consumer_pk }) do
    len = len + 1
    groups[len] = get_consumer_group(row.consumer_group.id)
    if err then
      return nil, err
    end
  end
  if len == 0 then
    return nil
  end
  return groups
end

return {
    get_consumer_group = get_consumer_group,
    get_consumer_group_config = get_consumer_group_config,
    get_consumers_in_group = get_consumers_in_group,
    delete_consumer_in_group = delete_consumer_in_group,
    get_groups_by_consumer = get_groups_by_consumer,
    is_consumer_in_group = is_consumer_in_group,
    get_plugins_in_group = get_plugins_in_group,
    select_by_username_or_id = select_by_username_or_id,
  }