import Config

config :stallalert, windguru_adapter: Stallalert.Windguru.HTTPAdapter
config :stallalert, windguru_req_options: []

import_config "#{config_env()}.exs"
