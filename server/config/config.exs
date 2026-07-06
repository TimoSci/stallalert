import Config

config :stallalert, windguru_adapter: Stallalert.Windguru.HTTPAdapter

import_config "#{config_env()}.exs"
