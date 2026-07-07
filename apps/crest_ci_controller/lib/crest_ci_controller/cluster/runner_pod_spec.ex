defmodule CrestCiController.Cluster.RunnerPodSpec do
  @moduledoc """
  The fields the controller renders into a real Kubernetes `Pod` object for
  one `RunnerJob`.

  This is a pure value object: a plain struct with validation and
  (de)serialization to/from the Kubernetes JSON wire shape (camelCase
  keys). It holds no reference to any live connection, has no I/O, and
  cannot itself talk to a cluster — the `ReqKubeClient` adapter (or the
  in-BEAM mock) is what actually creates the `Pod`, taking a rendered
  manifest built from a validated `RunnerPodSpec` as input. Keeping the
  shaping logic here and the transport in the adapter is what lets `Pod`
  shaping be tested with zero network and zero mock server.

  `name` must already be the deterministic child-object name the caller
  derived from the parent `RunnerJob` (run ULID + job key) before this
  module ever sees it — deterministic naming is what makes a 409
  `AlreadyExists` on `create` a safe no-op after a failover
  re-reconcile, per the project's child-resource invariant. This module
  does not derive that name; it only validates that whatever name it is
  handed is a legal Kubernetes object name.

  Resource fields (`cpu_request`, `cpu_limit`, `mem_request`,
  `mem_limit`) default to the laptop profile from D2 §10 — requests
  `100m` / `256Mi`, limits `500m` / `768Mi` — when omitted from `new/1`'s
  `fields` map, so callers that don't care about resource tuning (tests,
  the mock-cluster demo path) get a sane, small footprint for free.
  `new/1` also enforces that each limit is not smaller than its matching
  request: a `RunnerPodSpec` where the limit is below the request would
  describe a `Pod` the kubelet could never actually admit consistently,
  so that shape is rejected here rather than surfacing later as an
  opaque scheduling failure.
  """

  @enforce_keys [:name, :namespace, :image, :service_account, :active_deadline_seconds]
  defstruct name: nil,
            namespace: nil,
            image: nil,
            service_account: nil,
            active_deadline_seconds: nil,
            cpu_request: "100m",
            cpu_limit: "500m",
            mem_request: "256Mi",
            mem_limit: "768Mi",
            env: %{},
            labels: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t(),
          image: String.t(),
          service_account: String.t(),
          active_deadline_seconds: pos_integer(),
          cpu_request: String.t(),
          cpu_limit: String.t(),
          mem_request: String.t(),
          mem_limit: String.t(),
          env: %{optional(String.t()) => String.t()},
          labels: %{optional(String.t()) => String.t()}
        }

  @type build_error ::
          {:invalid_name, term()}
          | {:invalid_namespace, term()}
          | {:invalid_image, term()}
          | {:invalid_service_account, term()}
          | {:invalid_active_deadline_seconds, term()}
          | {:invalid_cpu_request, term()}
          | {:invalid_cpu_limit, term()}
          | {:invalid_mem_request, term()}
          | {:invalid_mem_limit, term()}
          | {:cpu_limit_below_request, cpu_limit :: String.t(), cpu_request :: String.t()}
          | {:mem_limit_below_request, mem_limit :: String.t(), mem_request :: String.t()}
          | {:invalid_env, term()}
          | {:invalid_labels, term()}

  # Kubernetes DNS-1123 subdomain: lowercase alphanumeric, '-', '.',
  # segments cannot start/end with '-' or '.'. Used for `name` (a Pod
  # name) with the 253-char subdomain limit.
  @dns_subdomain_regex ~r/^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/

  # Kubernetes DNS-1123 label: like a subdomain segment but no dots, and
  # capped at 63 chars. Used for `namespace` and `service_account`.
  @dns_label_regex ~r/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/

  # Kubernetes label name/value segment (case-insensitive, allows
  # '_' and '.' in addition to '-').
  @label_segment_regex ~r/^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$/

  # A conventional shell/POSIX environment variable name.
  @env_key_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @cpu_quantity_regex ~r/^\d+(\.\d+)?m?$/
  @mem_quantity_regex ~r/^(?<num>\d+(?:\.\d+)?)(?<suffix>Ki|Mi|Gi|Ti|Pi|Ei|K|M|G|T|P|E)?$/

  @mem_multipliers %{
    "" => 1,
    "K" => 1_000,
    "M" => 1_000_000,
    "G" => 1_000_000_000,
    "T" => 1_000_000_000_000,
    "P" => 1_000_000_000_000_000,
    "E" => 1_000_000_000_000_000_000,
    "Ki" => 1024,
    "Mi" => 1024 * 1024,
    "Gi" => 1024 * 1024 * 1024,
    "Ti" => 1024 * 1024 * 1024 * 1024,
    "Pi" => 1024 * 1024 * 1024 * 1024 * 1024,
    "Ei" => 1024 * 1024 * 1024 * 1024 * 1024 * 1024
  }

  @doc """
  Builds a new `RunnerPodSpec` from field values (atom keys).

  `name`, `namespace`, `image`, `service_account`, and
  `active_deadline_seconds` are required. `cpu_request`, `cpu_limit`,
  `mem_request`, `mem_limit`, `env`, and `labels` default to the laptop
  profile (see moduledoc) when omitted.

  Returns `{:error, reason}` on the first invalid field or invariant
  violation rather than trying to build a partially-invalid struct.
  """
  @spec new(map()) :: {:ok, t()} | {:error, build_error()}
  def new(fields) when is_map(fields) do
    with {:ok, name} <- validate_name(Map.get(fields, :name)),
         {:ok, namespace} <- validate_namespace(Map.get(fields, :namespace)),
         {:ok, image} <- validate_image(Map.get(fields, :image)),
         {:ok, service_account} <- validate_service_account(Map.get(fields, :service_account)),
         {:ok, active_deadline_seconds} <-
           validate_active_deadline_seconds(Map.get(fields, :active_deadline_seconds)),
         {:ok, cpu_request} <-
           validate_cpu_quantity(Map.get(fields, :cpu_request, "100m"), :invalid_cpu_request),
         {:ok, cpu_limit} <-
           validate_cpu_quantity(Map.get(fields, :cpu_limit, "500m"), :invalid_cpu_limit),
         {:ok, mem_request} <-
           validate_mem_quantity(Map.get(fields, :mem_request, "256Mi"), :invalid_mem_request),
         {:ok, mem_limit} <-
           validate_mem_quantity(Map.get(fields, :mem_limit, "768Mi"), :invalid_mem_limit),
         :ok <- validate_cpu_limit_not_below_request(cpu_limit, cpu_request),
         :ok <- validate_mem_limit_not_below_request(mem_limit, mem_request),
         {:ok, env} <- validate_string_map(Map.get(fields, :env, %{}), :invalid_env),
         {:ok, env} <- validate_env_keys(env),
         {:ok, labels} <- validate_string_map(Map.get(fields, :labels, %{}), :invalid_labels),
         {:ok, labels} <- validate_labels(labels) do
      {:ok,
       %__MODULE__{
         name: name,
         namespace: namespace,
         image: image,
         service_account: service_account,
         active_deadline_seconds: active_deadline_seconds,
         cpu_request: cpu_request,
         cpu_limit: cpu_limit,
         mem_request: mem_request,
         mem_limit: mem_limit,
         env: env,
         labels: labels
       }}
    end
  end

  @doc """
  Decodes a `RunnerPodSpec` from its Kubernetes JSON wire shape: a map
  with camelCase string keys (`activeDeadlineSeconds`, `cpuLimit`,
  `cpuRequest`, `env`, `image`, `labels`, `memLimit`, `memRequest`,
  `name`, `namespace`, `serviceAccount`).
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, build_error()}
  def from_wire(%{} = wire) do
    fields = %{
      name: Map.get(wire, "name"),
      namespace: Map.get(wire, "namespace"),
      image: Map.get(wire, "image"),
      service_account: Map.get(wire, "serviceAccount"),
      active_deadline_seconds: Map.get(wire, "activeDeadlineSeconds")
    }

    fields =
      fields
      |> maybe_put(:cpu_request, Map.get(wire, "cpuRequest"))
      |> maybe_put(:cpu_limit, Map.get(wire, "cpuLimit"))
      |> maybe_put(:mem_request, Map.get(wire, "memRequest"))
      |> maybe_put(:mem_limit, Map.get(wire, "memLimit"))
      |> maybe_put(:env, Map.get(wire, "env"))
      |> maybe_put(:labels, Map.get(wire, "labels"))

    new(fields)
  end

  @doc "Encodes a `RunnerPodSpec` into its Kubernetes JSON wire shape (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = spec) do
    %{
      "activeDeadlineSeconds" => spec.active_deadline_seconds,
      "cpuLimit" => spec.cpu_limit,
      "cpuRequest" => spec.cpu_request,
      "env" => spec.env,
      "image" => spec.image,
      "labels" => spec.labels,
      "memLimit" => spec.mem_limit,
      "memRequest" => spec.mem_request,
      "name" => spec.name,
      "namespace" => spec.namespace,
      "serviceAccount" => spec.service_account
    }
  end

  defp maybe_put(fields, _key, nil), do: fields
  defp maybe_put(fields, key, value), do: Map.put(fields, key, value)

  # -- field validation -------------------------------------------------

  @spec validate_name(term()) :: {:ok, String.t()} | {:error, {:invalid_name, term()}}
  defp validate_name(name)
       when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 253 do
    if Regex.match?(@dns_subdomain_regex, name) do
      {:ok, name}
    else
      {:error, {:invalid_name, name}}
    end
  end

  defp validate_name(other), do: {:error, {:invalid_name, other}}

  @spec validate_namespace(term()) :: {:ok, String.t()} | {:error, {:invalid_namespace, term()}}
  defp validate_namespace(namespace)
       when is_binary(namespace) and byte_size(namespace) > 0 and byte_size(namespace) <= 63 do
    if Regex.match?(@dns_label_regex, namespace) do
      {:ok, namespace}
    else
      {:error, {:invalid_namespace, namespace}}
    end
  end

  defp validate_namespace(other), do: {:error, {:invalid_namespace, other}}

  @spec validate_image(term()) :: {:ok, String.t()} | {:error, {:invalid_image, term()}}
  defp validate_image(image) when is_binary(image) and byte_size(image) > 0, do: {:ok, image}
  defp validate_image(other), do: {:error, {:invalid_image, other}}

  @spec validate_service_account(term()) ::
          {:ok, String.t()} | {:error, {:invalid_service_account, term()}}
  defp validate_service_account(service_account)
       when is_binary(service_account) and byte_size(service_account) > 0 and
              byte_size(service_account) <= 253 do
    if Regex.match?(@dns_label_regex, service_account) do
      {:ok, service_account}
    else
      {:error, {:invalid_service_account, service_account}}
    end
  end

  defp validate_service_account(other), do: {:error, {:invalid_service_account, other}}

  @spec validate_active_deadline_seconds(term()) ::
          {:ok, pos_integer()} | {:error, {:invalid_active_deadline_seconds, term()}}
  defp validate_active_deadline_seconds(seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, seconds}

  defp validate_active_deadline_seconds(other),
    do: {:error, {:invalid_active_deadline_seconds, other}}

  @spec validate_cpu_quantity(term(), atom()) :: {:ok, String.t()} | {:error, {atom(), term()}}
  defp validate_cpu_quantity(value, error_tag) when is_binary(value) do
    if Regex.match?(@cpu_quantity_regex, value) do
      {:ok, value}
    else
      {:error, {error_tag, value}}
    end
  end

  defp validate_cpu_quantity(value, error_tag), do: {:error, {error_tag, value}}

  @spec validate_mem_quantity(term(), atom()) :: {:ok, String.t()} | {:error, {atom(), term()}}
  defp validate_mem_quantity(value, error_tag) when is_binary(value) do
    if Regex.match?(@mem_quantity_regex, value) do
      {:ok, value}
    else
      {:error, {error_tag, value}}
    end
  end

  defp validate_mem_quantity(value, error_tag), do: {:error, {error_tag, value}}

  @spec validate_cpu_limit_not_below_request(String.t(), String.t()) ::
          :ok | {:error, {:cpu_limit_below_request, String.t(), String.t()}}
  defp validate_cpu_limit_not_below_request(cpu_limit, cpu_request) do
    if cpu_to_millicores(cpu_limit) >= cpu_to_millicores(cpu_request) do
      :ok
    else
      {:error, {:cpu_limit_below_request, cpu_limit, cpu_request}}
    end
  end

  @spec validate_mem_limit_not_below_request(String.t(), String.t()) ::
          :ok | {:error, {:mem_limit_below_request, String.t(), String.t()}}
  defp validate_mem_limit_not_below_request(mem_limit, mem_request) do
    if mem_to_bytes(mem_limit) >= mem_to_bytes(mem_request) do
      :ok
    else
      {:error, {:mem_limit_below_request, mem_limit, mem_request}}
    end
  end

  @spec cpu_to_millicores(String.t()) :: float()
  defp cpu_to_millicores(value) do
    if String.ends_with?(value, "m") do
      value |> String.trim_trailing("m") |> parse_number()
    else
      value |> parse_number() |> Kernel.*(1000)
    end
  end

  @spec mem_to_bytes(String.t()) :: float()
  defp mem_to_bytes(value) do
    %{"num" => number, "suffix" => suffix} = Regex.named_captures(@mem_quantity_regex, value)
    parse_number(number) * Map.fetch!(@mem_multipliers, suffix)
  end

  # Parses the leading numeric literal of a quantity string (already
  # known, via the caller's regex match, to be a valid unsigned integer
  # or decimal) into a float, without depending on any suffix being
  # present.
  @spec parse_number(String.t()) :: float()
  defp parse_number(number) do
    case Float.parse(number) do
      {value, ""} -> value
      :error -> number |> String.to_integer() |> :erlang.float()
    end
  end

  @spec validate_string_map(term(), atom()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, {atom(), term()}}
  defp validate_string_map(map, error_tag) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, map}
    else
      {:error, {error_tag, map}}
    end
  end

  defp validate_string_map(other, error_tag), do: {:error, {error_tag, other}}

  @spec validate_env_keys(%{optional(String.t()) => String.t()}) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, {:invalid_env, term()}}
  defp validate_env_keys(env) do
    if Enum.all?(env, fn {k, _v} -> Regex.match?(@env_key_regex, k) end) do
      {:ok, env}
    else
      {:error, {:invalid_env, env}}
    end
  end

  @spec validate_labels(%{optional(String.t()) => String.t()}) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, {:invalid_labels, term()}}
  defp validate_labels(labels) do
    if Enum.all?(labels, fn {k, v} -> valid_label_key?(k) and valid_label_value?(v) end) do
      {:ok, labels}
    else
      {:error, {:invalid_labels, labels}}
    end
  end

  @spec valid_label_key?(String.t()) :: boolean()
  defp valid_label_key?(key) when byte_size(key) > 0 and byte_size(key) <= 253 do
    case String.split(key, "/", parts: 2) do
      [name] ->
        valid_label_segment?(name, 63)

      [prefix, name] ->
        Regex.match?(@dns_subdomain_regex, prefix) and valid_label_segment?(name, 63)

      _ ->
        false
    end
  end

  defp valid_label_key?(_), do: false

  @spec valid_label_value?(String.t()) :: boolean()
  defp valid_label_value?(""), do: true
  defp valid_label_value?(value), do: valid_label_segment?(value, 63)

  @spec valid_label_segment?(String.t(), pos_integer()) :: boolean()
  defp valid_label_segment?(segment, max_len)
       when byte_size(segment) > 0 and byte_size(segment) <= max_len do
    Regex.match?(@label_segment_regex, segment)
  end

  defp valid_label_segment?(_, _), do: false
end

defimpl Jason.Encoder, for: CrestCiController.Cluster.RunnerPodSpec do
  def encode(spec, opts) do
    spec
    |> CrestCiController.Cluster.RunnerPodSpec.to_wire()
    |> Jason.Encode.map(opts)
  end
end
