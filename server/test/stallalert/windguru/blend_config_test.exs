defmodule Stallalert.Windguru.BlendConfigTest do
  # not async: uses persistent_term-backed fake + a persistent_term cache
  use ExUnit.Case
  @moduletag :capture_log

  alias Stallalert.FakeAdapter
  alias Stallalert.Windguru.BlendConfig

  # Authoritative snapshot, per the koef snapshot captured in
  # server/scripts/capture_fixtures.sh (2026-07-10) from
  # server/test/fixtures/windguru/forecast_spot.json tabs[0] (id_model=100,
  # spot 1189718). id_model_wave (84) is excluded from the constituent list.
  @expected_constituents [3, 117, 52, 107, 104, 64, 21, 43, 45, 59]
  @expected_koef %{
    3 => 1.0,
    117 => 1.0,
    52 => 1.0,
    107 => 1.0,
    104 => 1.0,
    64 => 1.0,
    21 => 1.0,
    43 => 1.0,
    45 => 0.9,
    59 => 0.7
  }

  setup do
    FakeAdapter.reset()
    BlendConfig.clear_cache()

    on_exit(fn -> BlendConfig.clear_cache() end)

    :ok
  end

  # Forces the test process to wait until the GenServer's mailbox has
  # drained any pending :refresh message. `:sys` system messages are
  # processed in plain mailbox (FIFO) order relative to regular messages
  # sent earlier by the same process, so this reliably waits for an
  # in-flight fetch triggered during init or via a prior `send/2`.
  defp sync(pid), do: :sys.get_state(pid)

  test "extracts constituents and koef from the fixture (id_model=100 tab)" do
    pid = start_supervised!({BlendConfig, name: nil})
    sync(pid)

    assert BlendConfig.weights() == %{
             constituents: @expected_constituents,
             koef: @expected_koef
           }
  end

  test "excludes id_model_wave (84) from constituents and koef" do
    pid = start_supervised!({BlendConfig, name: nil})
    sync(pid)

    weights = BlendConfig.weights()
    refute 84 in weights.constituents
    refute Map.has_key?(weights.koef, 84)
  end

  test "serves the hardcoded snapshot when the adapter errors" do
    FakeAdapter.set(:spot_config, {:error, :boom})

    pid = start_supervised!({BlendConfig, name: nil})
    sync(pid)

    assert BlendConfig.weights() == %{
             constituents: @expected_constituents,
             koef: @expected_koef
           }
  end

  test "refresh replaces values with a newly fetched spot config" do
    pid = start_supervised!({BlendConfig, name: nil})
    sync(pid)
    assert BlendConfig.weights().koef[45] == 0.9

    modified_fixture = %{
      "tabs" => [
        %{
          "id_model" => 100,
          "id_model_wave" => 84,
          "id_model_arr" => [
            %{"id_model" => 3},
            %{"id_model" => 117},
            %{"id_model" => 84}
          ],
          "blend" => %{
            "model_koef" => %{"3" => 0.5, "117" => 1}
          }
        }
      ]
    }

    FakeAdapter.set(:spot_config, {:ok, modified_fixture})
    send(pid, :refresh)
    sync(pid)

    assert BlendConfig.weights() == %{
             constituents: [3, 117],
             koef: %{3 => 0.5, 117 => 1.0}
           }
  end

  test "finds the id_model=100 tab even when it is not tabs[0]" do
    body = %{
      "tabs" => [
        %{"id_model" => 3, "id_model_arr" => [%{"id_model" => 3}]},
        %{
          "id_model" => 100,
          "id_model_wave" => 84,
          "id_model_arr" => [
            %{"id_model" => 3},
            %{"id_model" => 84}
          ],
          "blend" => %{"model_koef" => %{"3" => 1}}
        }
      ]
    }

    FakeAdapter.set(:spot_config, {:ok, body})
    pid = start_supervised!({BlendConfig, name: nil})
    sync(pid)

    assert BlendConfig.weights() == %{constituents: [3], koef: %{3 => 1.0}}
  end

  test "keeps the snapshot and logs a warning when no tab has id_model=100" do
    body = %{
      "tabs" => [
        %{"id_model" => 3, "id_model_arr" => [%{"id_model" => 3}]}
      ]
    }

    FakeAdapter.set(:spot_config, {:ok, body})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start_supervised!({BlendConfig, name: nil})
        sync(pid)
      end)

    assert log =~ "id_model"

    assert BlendConfig.weights() == %{
             constituents: @expected_constituents,
             koef: @expected_koef
           }
  end
end
