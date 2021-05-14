-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"


local UDP_PROXY_PORT = 26001


for _, strategy in helpers.each_strategy() do

  describe("UDP Proxying [#" .. strategy .. "]", function()
    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
      })

      local service = assert(bp.services:insert {
        name = "udp-service",
        url = "udp://127.0.0.1:" .. helpers.mock_upstream_stream_port,
      })

      assert(bp.routes:insert {
        protocols = { "udp" },
        service = service,
        sources = { { ip = "127.0.0.1", }, }
      })

      assert(helpers.start_kong {
        database = strategy,
        nginx_conf  = "spec/fixtures/custom_nginx.template",
        stream_listen = "127.0.0.1:" .. UDP_PROXY_PORT .. " udp",
      })

    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    it("proxies udp", function()
      local client = ngx.socket.udp()
      assert(client:setpeername("127.0.0.1", UDP_PROXY_PORT))

      assert(client:send("HELLO WORLD!\n"))
      local echo = assert(client:receive())

      assert.equal("HELLO WORLD!\n", echo)
    end)
  end)
end