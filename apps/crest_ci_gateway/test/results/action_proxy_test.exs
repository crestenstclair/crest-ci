defmodule CrestCiGateway.Results.ActionProxyTest do
  use ExUnit.Case, async: true

  alias CrestCiGateway.Results.ActionProxy

  defmodule FakeProxy do
    @moduledoc false
    @behaviour ActionProxy

    @enforce_keys [:fetch_log]
    defstruct [:fetch_log]

    def new(fetch_log) when is_pid(fetch_log) do
      %__MODULE__{fetch_log: fetch_log}
    end

    @impl ActionProxy
    def resolve(%__MODULE__{fetch_log: fetch_log}, repo, ref) do
      send(fetch_log, {:resolve, repo, ref})
      {:ok, Path.join(["var", "actions", slug(repo), ref <> ".tgz"])}
    end

    defp slug(repo), do: String.replace(repo, "/", "-")
  end

  defmodule FailingProxy do
    @moduledoc false
    @behaviour ActionProxy

    defstruct []

    @impl ActionProxy
    def resolve(%__MODULE__{}, _repo, _ref), do: {:error, :not_found}
  end

  describe "resolve/3" do
    test "dispatches to the implementation identified by the proxy struct's own module" do
      proxy = FakeProxy.new(self())

      assert {:ok, path} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      assert path == "var/actions/actions-checkout/v4.tgz"
      assert_received {:resolve, "actions/checkout", "v4"}
    end

    test "propagates {:error, term} from the implementation unchanged" do
      assert {:error, :not_found} =
               ActionProxy.resolve(%FailingProxy{}, "actions/setup-node", "v5")
    end

    test "is content-addressed: the same (repo, ref) always resolves to the same path" do
      proxy = FakeProxy.new(self())

      assert {:ok, path1} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      assert {:ok, path2} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      assert path1 == path2

      assert_received {:resolve, "actions/checkout", "v4"}
      assert_received {:resolve, "actions/checkout", "v4"}
    end

    test "distinct refs of the same repo resolve to distinct paths" do
      proxy = FakeProxy.new(self())

      assert {:ok, path_v4} = ActionProxy.resolve(proxy, "actions/checkout", "v4")
      assert {:ok, path_v3} = ActionProxy.resolve(proxy, "actions/checkout", "v3")
      refute path_v4 == path_v3
    end
  end
end
