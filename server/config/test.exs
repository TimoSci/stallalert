import Config

config :stallalert, windguru_adapter: Stallalert.FakeAdapter
config :stallalert, start_server: false
config :stallalert, api_token: "test-token"
config :stallalert, windguru_req_options: [plug: {Req.Test, Stallalert.Windguru.HTTPAdapter}]
