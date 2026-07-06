import Config

if config_env() == :prod do
  config :stallalert,
    api_token: System.fetch_env!("API_TOKEN")
end
