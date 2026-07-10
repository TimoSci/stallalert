import Config

config :stallalert, windguru_adapter: Stallalert.FakeAdapter
config :stallalert, start_server: false
config :stallalert, api_token: "test-token"
config :stallalert, windguru_req_options: [plug: {Req.Test, Stallalert.Windguru.HTTPAdapter}]

# `HTTPAdapter`'s `:wg` blend path sleeps this long between consecutive LIVE
# (non-cached) constituent fetches (default 2_500ms in prod, see
# `HTTPAdapter`'s `@default_fetch_spacing_ms`). Zeroed here so stubbed test
# suites exercising several live constituent fetches per case don't take
# minutes to run.
config :stallalert, windguru_fetch_spacing_ms: 0
