import Config

config :stallalert, api_token: System.get_env("API_TOKEN", "dev-token")
