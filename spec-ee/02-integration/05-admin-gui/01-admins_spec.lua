local helpers    = require "spec.helpers"
local cjson      = require "cjson"
local enums      = require "kong.enterprise_edition.dao.enums"
local utils      = require "kong.tools.utils"
local ee_jwt     = require "kong.enterprise_edition.jwt"
local ee_utils   = require "kong.enterprise_edition.utils"
local ee_helpers = require "spec-ee.helpers"
local escape = require("socket.url").escape


local post = ee_helpers.post


for _, strategy in helpers.each_strategy() do
  describe("Admin API - Admins #" .. strategy, function()
    local client
    local db
    local dao
    local bp
    local admin, proxy_consumer
    local another_ws
    local admins = {}

    lazy_setup(function()
      bp, db, dao = helpers.get_db_utils(strategy, {
        "consumers",
        "rbac_users",
        "rbac_roles",
        "rbac_user_roles",
        "admins",
      })
      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        -- TODO: Re-enable when auth plugins work again
        --admin_gui_auth = "basic-auth",
        --enforce_rbac = "on",
      }))

      another_ws = assert(bp.workspaces:insert({
        name = "another-one",
      }))

      ee_helpers.register_rbac_resources(dao)
      ee_helpers.register_token_statuses(dao)

      for i = 1, 3 do
        -- admins that are already approved
        admins[i] = assert(db.admins:insert {
          username = "admin-" .. i .. "@test.com",
          custom_id = "admin-" .. i,
          email = "admin-" .. i .. "@test.com",
          status = enums.CONSUMERS.STATUS.APPROVED,
        })
      end
      admins[4] = assert(db.admins:insert {
        username = "admin-4@test.com",
        custom_id = "admin-4",
        email = "admin-4@test.com",
        status = enums.CONSUMERS.STATUS.INVITED,
      })
      -- developers don't show up as admins
      assert(bp.consumers:insert {
        username = "developer-1",
        custom_id = "developer-1",
        type = enums.CONSUMERS.TYPE.DEVELOPER,
      })

      -- proxy users don't show up as admins
      proxy_consumer = assert(bp.consumers:insert {
        username = "consumer-1",
        custom_id = "consumer-1",
        type = enums.CONSUMERS.TYPE.PROXY,
      })

      admin = admins[1]
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
    end)

    describe("/admins", function()
      describe("GET", function ()
        it("retrieves list of admins only", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins?type=2",
            headers = {
              ["Kong-Admin-Token"] = "letmein",
            },
          })

          res = assert.res_status(200, res)
          local json = cjson.decode(res)
          assert.equal(4, #json.data)
        end)

      end)

      describe("POST", function ()
        it("creates an admin", function()
          local res = assert(client:send {
            method = "POST",
            path  = "/admins",
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
            body  = {
              custom_id = "cooper",
              username  = "dale",
              email = "Twinpeaks@KongHQ.com",
              status = enums.CONSUMERS.STATUS.INVITED,
            },
          })
          res = assert.res_status(200, res)
          local json = cjson.decode(res)

          -- TODO: should the response be nested under 'admin' like this,
          -- or kept at top-level like other entities? The original sin here
          -- was returning { consumer = foo, rbac_user = bar, message = hi }.
          assert.equal("dale", json.admin.username)
          assert.equal("cooper", json.admin.custom_id)
          assert.equal("twinpeaks@konghq.com", json.admin.email)
          assert.equal(enums.CONSUMERS.STATUS.INVITED, json.admin.status)
        end)
      end)
    end)

    describe("/admins/:admin_id", function()
      describe("GET", function()
        it("retrieves by id", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/" .. admins[1].id,
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })

          local body = assert.res_status(200, res)
          local json = cjson.decode(body)

          assert.same(admins[1].id, json.id)
        end)

        it("retrieves by username", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/" .. escape("admin-2@test.com"),
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(admins[2].id, json.id)
        end)

        it("includes token for invited user", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/" .. escape("admin-4@test.com") .. "?generate_register_url=true",
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(admins[4].id, json.id)
          assert.not_nil(json.token)
          assert.not_nil(json.register_url)
        end)

        it("returns 404 if not found", function()
          local res = assert(client:send {
            method = "GET",
            path = "/admins/not-an-admin",
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })
          assert.res_status(404, res)
        end)
      end)

      describe("PATCH", function()
        it("updates by id", function()
          return function()
            local res = assert(client:send {
              method = "PATCH",
              path = "/admins/" .. admin.id,
              body = {
                username = "alice",
                email = "ALICE@kongHQ.com",
              },
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })

            local json = cjson.decode(assert.res_status(200, res))
            assert.equal("alice", json.username)
            assert.equal("alice@konghq.com", json.email)
            assert.equal(admin.id, json.id)
          end
        end)

        it("updates by username", function()
          return function()
            local res = assert(client:send {
              method = "PATCH",
              path = "/admins/" .. admin.username,
              body = {
                username = "alice"
              },
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })
            local body = assert.res_status(200, res)
            local json = cjson.decode(body)
            assert.equal("alice", json.username)
            assert.equal(admin.id, json.id)
          end
        end)

        it("returns 404 if not found", function()
          return function()
            local res = assert(client:send {
              method = "PATCH",
              path = "/admins/not-an-admin",
              body = {
               username = "alice"
              },
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })
            assert.res_status(404, res)
          end
        end)
      end)

      describe("DELETE", function()
        it("deletes by id", function()
          local admin = assert(db.admins:insert({
            username = "deleteme" .. utils.uuid(),
            email = "deleteme@konghq.com",
            status = enums.CONSUMERS.STATUS.INVITED,
          }))

          local res = assert(client:send {
            method = "DELETE",
            path   = "/admins/" .. admin.id,
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(204, res)
          assert.equal("", body)
        end)

        it("deletes by username", function()
          local admin = assert(db.admins:insert({
            username = "gruce-delete-me",
            email = "deleteme@konghq.com",
            status = enums.CONSUMERS.STATUS.INVITED,
          }))

          local res = assert(client:send {
            method = "DELETE",
            path   = "/admins/" .. admin.username,
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })
          local body = assert.res_status(204, res)
          assert.equal("", body)
        end)

        it("returns 404 if not found", function()
          local res = assert(client:send {
            method = "DELETE",
            path   = "/admins/not-an-admin",
            headers = {
              ["Kong-Admin-Token"] = "letmein",
              ["Content-Type"]     = "application/json",
            },
          })
          assert.res_status(404, res)
        end)
      end)

      pending("/admins/:consumer_id/workspaces", function()
        describe("GET", function()
          it("retrieves workspaces", function()
            local res = assert(client:send {
              method = "POST",
              path = "/admins",
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
              body  = {
                custom_id = "get-cooper",
                username  = "get-dale",
                email = "dale-twinpeaks@konghq.com",
              },
            })

            local body = assert.res_status(200, res)
            admin = cjson.decode(body)

            local res = assert(client:send {
              method = "GET",
              path = "/admins/" .. admin.consumer.id .. "/workspaces",
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            assert.equal(1, #json)
            assert.equal("default", json[1].name)
          end)

          it("returns multiple workspaces admin belongs to", function()
            local res = assert(client:send {
              method = "POST",
              path = "/workspaces/" .. another_ws.name .. "/entities",
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
              body  = {
                entities = admin.consumer.id .. "," .. admin.rbac_user.id
              },
            })
            assert.res_status(201, res)

            local res = assert(client:send {
              method = "GET",
              path = "/admins/" .. admin.consumer.id .. "/workspaces",
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })

            local body = assert.res_status(200, res)
            local json = cjson.decode(body)

            local names = { json[1].name, json[2].name }
            assert.equal(2, #json)
            assert.contains("default", names)
            assert.contains(another_ws.name, names)
          end)

          it("returns 404 if not found", function()
            local res = assert(client:send {
              method = "GET",
              path = "/admins/" .. admin.rbac_user.id .. "/workspaces",
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })
            assert.res_status(404, res)
          end)

          it("returns 404 if consumer is not of type admin", function()
            local res = assert(client:send {
              method = "GET",
              path = "/admins/" .. proxy_consumer.id .. "/workspaces",
              headers = {
                ["Kong-Admin-Token"] = "letmein",
                ["Content-Type"]     = "application/json",
              },
            })
            assert.res_status(404, res)
          end)
        end)
      end)
    end)
  end)

  pending("Admin API - Admins Register #" .. strategy, function()
    local client
    local dao

    describe("/admins/register basic-auth", function()
      local headers = {
        ["Content-Type"] = "application/json",
        ["Kong-Admin-Token"] = "letmein",
      }

      before_each(function()
        _, _, dao = helpers.get_db_utils(strategy)
        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = 'basic-auth',
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(dao)
        ee_helpers.register_token_statuses(dao)
        client = assert(helpers.admin_client())
      end)

      after_each(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      describe("/admins/register", function()
        it("denies invalid emails", function()
          local res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json",
            },
            body  = {
              username  = "dale",
              email = "not-valid.com",
            },
          })

          local body = assert.res_status(400, res)
          local json = cjson.decode(body)
          assert.truthy(string.match(json.message, "Invalid email"))
        end)

        it("successfully registers an invited admin", function()
          local admin = post(client, "/admins", {
                                      username = "bob",
                                      email = "hong@konghq.com",
                                    }, headers, 200)

          local reset_secret = dao.consumer_reset_secrets:find_all({
            consumer_id = admin.consumer.id
          })[1]
          assert.equal(enums.TOKENS.STATUS.PENDING, reset_secret.status)

          local claims = {id = admin.consumer.id, exp = ngx.time() + 100000}
          local valid_jwt = ee_jwt.generate_JWT(claims, reset_secret.secret,
                                                "HS256")

          local res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json"
            },
            body  = {
              username = "bob",
              email = "hong@konghq.com",
              token = valid_jwt,
              password = "clawz"
            },
          })

          local body = assert.res_status(201, res)
          local json = cjson.decode(body)
          assert.equal("bob", json.consumer.username)
          assert.equal("bob", json.credential.username)
          assert.is.falsy("clawz" == json.credential.password)

          reset_secret = dao.consumer_reset_secrets:find_all({
            id = reset_secret.id
          })[1]

          assert.equal(enums.TOKENS.STATUS.CONSUMED, reset_secret.status)
        end)
      end)
    end)

    pending("/admins/register ldap-auth-advanced", function()
      local headers = {
        ["Content-Type"] = "application/json",
        ["Kong-Admin-Token"] = "letmein", -- super-admin
      }

      before_each(function()
        _, _, dao = helpers.get_db_utils(strategy)
        assert(helpers.start_kong({
          database = strategy,
          admin_gui_url = "http://manager.konghq.com",
          admin_gui_auth = 'ldap-auth-advanced',
          enforce_rbac = "on",
        }))
        ee_helpers.register_rbac_resources(dao)
        ee_helpers.register_token_statuses(dao)
        client = assert(helpers.admin_client())
      end)

      after_each(function()
        if client then client:close() end
        assert(helpers.stop_kong())
      end)

      describe("/admins/register", function()
        it("cannot register an invited admin with ldap", function()
          local admin = post(client, "/admins", {
                                      username = "bob",
                                      email = "hong@konghq.com",
                                    }, headers, 200)

          local reset_secret = dao.consumer_reset_secrets:find_all({
            consumer_id = admin.consumer.id
          })[1]
          assert.equal(nil, reset_secret)

          local res = assert(client:send {
            method = "POST",
            path = "/admins/register",
            headers = {
              ["Content-Type"] = "application/json"
              -- no auth headers!
            },
            body  = {
              username = "bob",
              email = "hong@konghq.com",
              password = "clawz"
            },
          })

          assert.res_status(400, res)
        end)
      end)
    end)
  end)

  pending("Admin API - auto-approval #" .. strategy, function()
    local client
    local dao
    local consumer

    before_each(function()
      _, _, dao = helpers.get_db_utils(strategy)
      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_auth = 'basic-auth',
        enforce_rbac = "on",
      }))
      ee_helpers.register_rbac_resources(dao)
      ee_helpers.register_token_statuses(dao)
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
      assert(helpers.stop_kong())
    end)

    it("manages state transition for invited admins", function()
      -- create an admin who is pending
      local res = assert(client:send {
        method = "POST",
        path  = "/admins",
        headers = {
          ["Kong-Admin-Token"] = "letmein",
          ["Content-Type"] = "application/json",
        },
        body  = {
          custom_id = "gruce",
          username = "gruce@konghq.com",
          email = "gruce@konghq.com",
        },
      })
      res = assert.res_status(200, res)
      local json = cjson.decode(res)
      consumer = json.consumer

      -- he's invited
      assert.same(enums.CONSUMERS.STATUS.INVITED, consumer.status)

      -- add credentials for him
      assert(dao.basicauth_credentials:insert {
        username    = "gruce@konghq.com",
        password    = "kong",
        consumer_id = consumer.id,
      })

      -- make an API call
      assert(client:send{
        method = "GET",
        path = "/",
        headers = {
          ["Kong-Admin-User"] = "gruce@konghq.com",
          ["Authorization"] = "Basic " .. ngx.encode_base64("gruce@konghq.com:kong")
        }
      })

      local updated_consumers = dao.consumers:find_all { id = consumer.id }
      assert.same(enums.CONSUMERS.STATUS.APPROVED, updated_consumers[1].status)
    end)
  end)

  describe("Admin API - secret token generation #" .. strategy, function()
    local client
    local dao
    local consumer

    before_each(function()
      _, _, dao = helpers.get_db_utils(strategy)
      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_auth = 'basic-auth',
        enforce_rbac = "on",
      }))
      ee_helpers.register_rbac_resources(dao)
      ee_helpers.register_token_statuses(dao)
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
      assert(helpers.stop_kong())
    end)

    pending("generates a token and register_url for an invited admin", function()
      -- create an admin who is pending
      local res = assert(client:send {
        method = "POST",
        path  = "/admins",
        headers = {
          ["Kong-Admin-Token"] = "letmein",
          ["Content-Type"] = "application/json",
        },
        body  = {
          custom_id = "gruce",
          username = "gruce@konghq.com",
          email = "gruce@konghq.com",
        },
      })
      res = assert.res_status(200, res)
      local json = cjson.decode(res)
      consumer = json.consumer

      assert.same(enums.CONSUMERS.STATUS.INVITED, consumer.status)

      res = assert(client:send{
        method = "GET",
        path = "/admins/" .. consumer.id,
        headers = {
          ["Kong-Admin-Token"] = "letmein",
        }
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.is_nil(json.token)
      assert.is_nil(json.register_url)

      res = assert(client:send{
        method = "GET",
        path = "/admins/" .. consumer.id .. "?generate_register_url=true",
        headers = {
          ["Kong-Admin-Token"] = "letmein",
        }
      })

      body = assert.res_status(200, res)
      json = cjson.decode(body)

      local jwt, err = ee_utils.validate_reset_jwt(json.token)
      assert.is_nil(err)

      -- Look up the secret by consumer id and pending status
      local secrets, err = dao.consumer_reset_secrets:find_all({
        consumer_id = jwt.claims.id,
        status = enums.TOKENS.STATUS.PENDING,
      })
      assert.is_nil(err)

      assert.truthy(ee_jwt.verify_signature(jwt, secrets[1].secret))

      local url = ngx.unescape_uri(json.register_url)

      assert.truthy(string.match(url, "http://manager.konghq.com"))
      assert.truthy(string.match(url, consumer.username))
      assert.truthy(string.match(url, consumer.email))
      assert.truthy(string.match(url:gsub("%-", ""), json.token:gsub("%-", "")))
    end)
  end)

  pending("Admin API - /admins/password_resets #" .. strategy, function()
    local client
    local dao
    local admin

    before_each(function()
      _, _, dao = helpers.get_db_utils(strategy)
      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_auth = "basic-auth",
        enforce_rbac = "on",
      }))
      ee_helpers.register_rbac_resources(dao)
      ee_helpers.register_token_statuses(dao)
      client = assert(helpers.admin_client())

      local res = assert(client:send {
        method = "POST",
        path  = "/admins",
        headers = {
          ["Kong-Admin-Token"] = "letmein",
          ["Content-Type"] = "application/json",
        },
        body  = {
          custom_id = "gruce",
          username = "gruce",
          email = "gruce@konghq.com",
        }
      })
      res = assert.res_status(200, res)
      local json = cjson.decode(res)
      admin = json.consumer

      -- add credentials for him
      assert(dao.basicauth_credentials:insert {
        username    = "gruce",
        password    = "kong",
        consumer_id = admin.id,
      })
    end)

    after_each(function()
      if client then client:close() end
      assert(helpers.stop_kong())
    end)

    it("creates a consumer_reset_secret", function()
      local res = assert(client:send {
        method = "POST",
        path  = "/admins/password_resets",
        headers = {
          ["Content-Type"] = "application/json",
        },
        body  = {
          email = "gruce@konghq.com",
        }
      })
      assert.res_status(201, res)

      local resets, err = dao.consumer_reset_secrets:find_all({
        consumer_id = admin.id
      })

      assert.is_nil(err)

      -- one when he was invited, one when he forgot password
      assert.same(2, #resets)
    end)

    it("returns 404 if you're not an admin", function()
      local res = assert(client:send {
        method = "POST",
        path = "/admins/password_resets",
        headers = {
          ["Content-Type"] = "application/json",
        },
        body = {
          email = "developer-1@test.com",
        }
      })

      assert.res_status(404, res)
    end)

  end)

  describe("Admin API - /admins/password_resets for admin #" .. strategy, function()
    local client
    local dao

    before_each(function()
      _, _, dao = helpers.get_db_utils(strategy)
      assert(helpers.start_kong({
        database = strategy,
        admin_gui_url = "http://manager.konghq.com",
        admin_gui_auth = "ldap-auth-advanced",
        enforce_rbac = "on",
      }))
      ee_helpers.register_rbac_resources(dao)
      ee_helpers.register_token_statuses(dao)
      client = assert(helpers.admin_client())
    end)

    after_each(function()
      if client then client:close() end
      assert(helpers.stop_kong())
    end)

    it("returns 404 for 3rd-party auth", function()
      local res = assert(client:send {
        method = "POST",
        path = "/admins/password_resets",
        headers = {
          ["Content-Type"] = "application/json",
        },
        body = {
          email = "admin-1@test.com",
        }
      })

      assert.res_status(404, res)
    end)

  end)
end
