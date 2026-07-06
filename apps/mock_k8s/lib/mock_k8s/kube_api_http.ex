defmodule MockK8s.KubeApiHttp do
  @moduledoc """
  Port: HTTP facade exposing Kubernetes REST conventions over a
  `MockK8s.ResourceStore`.

  This module defines the *contract* only — it is the seam between the
  bounded context's pure domain (`MockK8s.ResourceStore`, `MockK8s.WatchHub`)
  and whatever concrete transport implements it (e.g. the `MockK8sHttpServer`
  adapter, built on Plug + Bandit). No transport-specific code (Plug, Bandit,
  Cowboy, ranch, sockets, ...) lives here — only the shape every
  implementation must satisfy.

  ## Why a behaviour, not a concrete server

  Controller and gateway code (and the conformance suite) must be able to
  depend on "something that serves the Kubernetes REST surface over a
  `ResourceStore`" without depending on a specific HTTP stack. Depending on
  the behaviour instead of a concrete module keeps the port replaceable
  (in-BEAM mock today, a different transport later) and keeps the domain
  (`ResourceStore` / `WatchHub`) free of any HTTP concern — the store never
  knows an HTTP server exists.

  ## Contract

      serve(store, port) -> {:ok, server}

  `store` is a reference to the running `MockK8s.ResourceStore` (and, by
  extension, its `MockK8s.WatchHub`) that the server fronts; it is opaque to
  this port — whatever a `ResourceStore` implementation hands back to
  identify itself (pid, name, or other term) is valid input here. `port` is
  the TCP port to bind; `0` requests an OS-assigned ephemeral port, and an
  implementation is expected to report back the port it actually bound (see
  `MockK8s.KubeApiHttp.Server.bound_port/1`) so callers never hard-code a
  port number.

  The routes, status codes, and error-body shape an implementation must
  provide are documented as the bounded-context design contract for
  `MockK8s`:

    * CRUD + list: `/apis/{group}/{version}/namespaces/{ns}/{plural}` and,
      for core-group kinds, `/api/v1/namespaces/{ns}/{plural}`
    * the `/status` subresource via `PUT` / `PATCH`, guarded by optimistic
      concurrency (`resourceVersion` compare-and-swap)
    * `?watch=true` streaming newline-delimited JSON `WatchEvent`s
    * `?limit=&continue=` chunked pagination
    * error bodies shaped like the Kubernetes `Status` object, with a
      machine-readable `reason` in
      `AlreadyExists | Conflict | NotFound | Gone`

  Registered kinds: `WorkflowDefinition`, `WorkflowRun`, `RunnerJob`,
  `RunnerPool` (`ci.crest.dev/v1alpha1`); `Lease` (`coordination.k8s.io/v1`);
  `Pod`, `Secret`, `ConfigMap` (`core/v1`).
  """

  @typedoc "Opaque handle to the ResourceStore (and its WatchHub) this server fronts."
  @type store :: term()

  @typedoc "TCP port to bind. `0` means \"pick an ephemeral port\"."
  @type port_number :: :inet.port_number()

  @typedoc "Opaque handle to the running server, returned to the caller for supervision/shutdown."
  @type server :: term()

  @typedoc "Kubernetes-shaped machine-readable failure reason."
  @type reason :: :already_exists | :conflict | :not_found | :gone | term()

  @doc """
  Start an HTTP facade in front of `store`, bound to `port`.

  Must not hold any authoritative state itself: every route is a thin
  translation between an HTTP request and a `MockK8s.ResourceStore` /
  `MockK8s.WatchHub` call, so the server can be killed and restarted without
  losing anything — the store is the only source of truth.
  """
  @callback serve(store, port_number) :: {:ok, server} | {:error, reason}
end
