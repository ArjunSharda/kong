-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local acme_schema = require "kong.plugins.acme.schema"
local v = require("spec.helpers").validate_plugin_config_schema

describe("Plugin: acme (schema)", function()

  local tests = {
    {
      name = "accepts valid config",
      input = {
        account_email = "example@example.com",
        api_uri = "https://api.acme.org",
      },
      error = nil
    },
    ----------------------------------------
    {
      name = "rejects invalid email",
      input = {
        account_email = "notaemail",
        api_uri = "https://api.acme.org",
      },
      error = {
        config = {
            account_email = "invalid value: notaemail"
        }
      }
    },
    ----------------------------------------
    {
        name = "must accpet ToS for Let's Encrypt (unaccpeted,staging)",
        input = {
          account_email = "example@example.com",
          api_uri = "https://acme-staging-v02.api.letsencrypt.org",
        },
        error = {
            ["@entity"] = {
                'terms of service must be accepted, see https://letsencrypt.org/repository/'
            },
            config = {
                tos_accepted = "value must be true",
            },
        },
      },
    ----------------------------------------
    {
        name = "must accpet ToS for Let's Encrypt (unaccpeted)",
        input = {
          account_email = "example@example.com",
          api_uri = "https://acme-v02.api.letsencrypt.org",
        },
        error = {
            ["@entity"] = {
                'terms of service must be accepted, see https://letsencrypt.org/repository/'
            },
            config = {
                tos_accepted = "value must be true",
            },
        },
      },
    ----------------------------------------
    {
        name = "must accpet ToS for Let's Encrypt (accepted)",
        input = {
          account_email = "example@example.com",
          api_uri = "https://acme-v02.api.letsencrypt.org",
          tos_accepted = true,
        },
      },
    ----------------------------------------
  }

  for _, t in ipairs(tests) do
    it(t.name, function()
      local output, err = v(t.input, acme_schema)
      assert.same(t.error, err)
      if t.error then
        assert.is_falsy(output)
      else
        assert.is_truthy(output)
      end
    end)
  end
end)