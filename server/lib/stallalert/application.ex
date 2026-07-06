defmodule Stallalert.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Stallalert.Conditions] ++
        if Application.get_env(:stallalert, :start_server, true) do
          [
            {Bandit,
             plug: Stallalert.Router, port: String.to_integer(System.get_env("PORT") || "4000")}
          ]
        else
          []
        end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Stallalert.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
