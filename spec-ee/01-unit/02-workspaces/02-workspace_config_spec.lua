-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local Schema = require "kong.db.schema"
local workspaces = require "kong.db.schema.entities.workspaces"


describe("workspace config", function()
  local schema

  setup(function()
    schema = Schema.new(workspaces)
  end)

  describe("schema", function()
    local snapshot

    before_each(function()
      snapshot = assert:snapshot()
    end)

    after_each(function()
      snapshot:revert()
    end)

    it("should accept properly formatted emails", function()
      local values = {
        name = "test",
        config = {
          portal_emails_from = "dog@kong.com",
          portal_emails_reply_to = "cat@kong.com",
        }
      }

      assert.truthy(schema:validate(values))
    end)

    it("should reject when email field is improperly formatted", function()
      local values = {
        name = "test",
        config = {
          portal_emails_from = "dog",
          portal_emails_reply_to = "cat",
        },
      }

      local ok, err = schema:validate(values)
      assert.falsy(ok)
      assert.equal("invalid email address dog", err.config["portal_emails_from"])
      assert.equal("invalid email address cat", err.config["portal_emails_reply_to"])
    end)

    it("should accept properly formatted token expiration", function()
      local values = {
        name = "test",
        config = {
          portal_token_exp = 1000,
        },
      }

      assert.truthy(schema:validate(values))
    end)

    it("should reject improperly formatted token expiration", function()
      local values = {
        name = "test",
        config = {
          portal_token_exp = -1000,
        },
      }

      local ok, err = schema:validate(values)
      assert.falsy(ok)
      assert.equal("value must be greater than -1", err.config["portal_token_exp"])
    end)

    it("should accept valid auth types", function()
      local values

      values = {
        name = "test",
        config = {
          portal_auth = "basic-auth",
        },
      }
      assert.truthy(schema:validate(values))

      values = {
        name = "test",
        config = {
          portal_auth = "key-auth",
        }
      }
      assert.truthy(schema:validate(values))

      values = {
        name = "test",
        config = {
          portal_auth = "openid-connect",
        },
      }
      assert.truthy(schema:validate(values))

      values = {
       name = "test",
       config = {
         portal_auth = "",
       },
      }
      assert.truthy(schema:validate(values))

      values = {
        name = "test",
        config = {
          portal_auth = nil,
        },
      }
      assert.truthy(schema:validate(values))
    end)

    it("should reject improperly formatted auth type", function()
      local values = {
        name = "test",
        config = {
          portal_auth = 'something-invalid',
        },
      }
      assert.falsy(schema:validate(values))
    end)

    it("should correctly merge new/old configs", function()
      local old_values = {
        name = "test",
        config = {
          portal = true,
          portal_auth = 'basic-auth',
        },
      }

      local new_values = {
        name = "test",
        config = {
          portal_auth = 'key-auth',
        },
      }

      local expected_values = {
        name = "test",
        config = {
          portal = true,
          portal_auth = 'key-auth',
        },
      }

      local values = schema:merge_values(new_values, old_values)

      assert.equals(values.config.portal, expected_values.config.portal)
      assert.equals(values.config.portal_auth, expected_values.config.portal_auth)
    end)

    it("should accept valid regex for portal_cors_origins", function()
      local values = {
        name = "test",
        config = {
          portal_cors_origins = { "wee" },
        },
      }

      assert.truthy(schema:validate(values))
    end)

    it("should accept '*' for portal_cors_origins", function()
      local values = {
        name = "test",
        config = {
          portal_cors_origins = { "*" },
        },
      }

      assert.truthy(schema:validate(values))
    end)

    it("should reject invalid regex (other than star) for portal_cors_origins", function()
      local values = {
        name = "test",
        config = {
          portal_cors_origins = { "[" },
        },
      }

      assert.falsy(schema:validate(values))
    end)

    it("should reject non string values for portal_cors_origins", function()
      local values = {
        name = "test",
        config = {
          portal_cors_origins = { 9000 },
        },
      }

      assert.falsy(schema:validate(values))
    end)
  end)
end)