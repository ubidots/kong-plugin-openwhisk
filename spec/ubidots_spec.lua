local helpers = require "spec.helpers"
local cjson   = require "cjson"


local OPENWHISK_HOST = "127.0.0.1"
local OPENWHISK_PORT = 10000
local OPENWHISK_PATH = "/api/v1/namespaces/guest"
local SERVICE_TOKEN = "openwhisk_auth_token"


local fixtures = {
  http_mock = {
    mock_openwhisk = [=[
      server {
          server_name mock_openwhisk;
          listen ]=] .. OPENWHISK_PORT .. [=[ ssl;

          ssl_certificate ${{SSL_CERT}};
          ssl_certificate_key ${{SSL_CERT_KEY}};
          ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;

          location ~ "]=] .. OPENWHISK_PATH .. [=[(.+)" {
              content_by_lua_block {
                local function x()
                  ngx.req.read_body()
                  local body = require("cjson").decode(ngx.req.get_body_data())

                  local answer = [[{"payload": "Hello, %s!"}]]
                  answer = answer:format(body.name or "World")
                  ngx.header["Content-Type"] = "application/json"
                  ngx.header["Content-Length"] = #answer
                  ngx.say(answer)
                  return ngx.exit(200)

                end
                local ok, err = pcall(x)
                if not ok then
                  ngx.log(ngx.ERR, "Mock error: ", err)
                end
              }
          }
      }
    ]=]
  },
}



describe("Plugin: openwhisk", function()
  local proxy, bp

  setup(function()
    bp = helpers.get_db_utils(nil, nil, {"openwhisk"})

    local route1 = assert(bp.routes:insert {
      name         = "test-openwhisk",
      hosts        = { "test.com" },
    })

    assert(bp.plugins:insert {
      route = { id = route1.id },
      name   = "openwhisk",
      config = {
        host          = OPENWHISK_HOST,
        port          = OPENWHISK_PORT,
        path          = OPENWHISK_PATH,
        service_token = SERVICE_TOKEN,
        action        = "hello",
        methods       = { "POST", "GET" },
      }
    })

    assert(helpers.start_kong({
      plugins = "bundled,openwhisk",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }, nil, nil, fixtures))

  end)

  teardown(function()
    helpers.stop_kong(nil, false)
  end)

  before_each(function()
    proxy = helpers.proxy_client()
  end)

  after_each(function()
    if proxy then proxy:close() end
  end)

  describe("invoke action hello", function()

    it("should allow POST", function()
      local res = assert(proxy:send {
        method  = "POST",
        path    = "/",
        body    = {},
        headers = {
          ["Host"] = "test.com"
        }
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.equal("Hello, World!", json.payload)
    end)

    it("should allow POST with querystring", function()
      local res = assert(proxy:send {
        method  = "POST",
        path    = "/?name=foo",
        body    = {},
        headers = {
          ["Host"] = "test.com"
        }
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.equal("Hello, foo!", json.payload)
    end)

    it("should allow POST with json body", function()
      local res = assert(proxy:send {
        method  = "POST",
        path    = "/",
        body    = { name = "foo" },
        headers = {
          ["Host"]         = "test.com",
          ["Content-Type"] = "application/json"
        }
      })

      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.equal("Hello, foo!", json.payload)
    end)

    it("should allow POST with form-encoded body", function()
      local res = assert(proxy:send {
        method  = "POST",
        path    = "/post",
        body    = {
          name  = "foo"
        },
        headers = {
          ["Host"]         = "test.com",
          ["Content-Type"] = "application/x-www-form-urlencoded"
        },

      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.equal("Hello, foo!", json.payload)
    end)

    it("should not allow GET", function()
      local res = assert(proxy:send {
        method  = "GET",
        path    = "/",
        body    = { name = "foo" },
        headers = {
          ["Host"]         = "test.com",
          ["Content-Type"] = "application/json"
        }
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(body)
      assert.equal("Hello, World!", json.payload)
    end)

    it("should not allow DELETE", function()
      local res = assert(proxy:send {
        method  = "DELETE",
        path    = "/",
        body    = { name = "foo" },
        headers = {
          ["Host"]         = "test.com",
          ["Content-Type"] = "application/json"
        }
      })
      local body = assert.res_status(405, res)
      local json = cjson.decode(body)
      assert.equal("The HTTP method used is not allowed in this endpoint.", json.message)
      assert.equal(405001, json.code)
    end)
  end)
end)
