defmodule CrestCiController.Engine.GithubContextTest do
  use ExUnit.Case, async: true

  alias CrestCiController.Engine.GithubContext

  describe "new/1" do
    test "builds a struct when every field is present" do
      assert {:ok, %GithubContext{} = context} =
               GithubContext.new(%{
                 actor: "octocat",
                 event: %{"foo" => "bar"},
                 event_name: "push",
                 ref: "refs/heads/main",
                 repository: "octo/repo",
                 sha: "abc123"
               })

      assert context.actor == "octocat"
      assert context.event == %{"foo" => "bar"}
      assert context.event_name == "push"
      assert context.ref == "refs/heads/main"
      assert context.repository == "octo/repo"
      assert context.sha == "abc123"
    end

    test "accepts empty-string fields and an empty event map (e.g. a bare schedule trigger)" do
      assert {:ok, %GithubContext{} = context} =
               GithubContext.new(%{
                 actor: "",
                 event: %{},
                 event_name: "schedule",
                 ref: "",
                 repository: "",
                 sha: ""
               })

      assert context.actor == ""
      assert context.event == %{}
    end

    test "rejects a non-binary actor" do
      assert {:error, :invalid_actor} =
               GithubContext.new(%{
                 actor: 42,
                 event: %{},
                 event_name: "push",
                 ref: "refs/heads/main",
                 repository: "octo/repo",
                 sha: "abc123"
               })
    end

    test "rejects a non-map event" do
      assert {:error, :invalid_event} =
               GithubContext.new(%{
                 actor: "octocat",
                 event: "not-a-map",
                 event_name: "push",
                 ref: "refs/heads/main",
                 repository: "octo/repo",
                 sha: "abc123"
               })
    end

    test "rejects a missing required field" do
      assert {:error, :invalid_sha} =
               GithubContext.new(%{
                 actor: "octocat",
                 event: %{},
                 event_name: "push",
                 ref: "refs/heads/main",
                 repository: "octo/repo"
               })
    end

    test "rejects a non-map argument entirely" do
      assert {:error, {:invalid_github_context, "nope"}} = GithubContext.new("nope")
    end
  end

  describe "from_event/2 — push" do
    test "derives ref/sha from the push payload and actor from pusher.name" do
      event = %{
        "ref" => "refs/heads/main",
        "after" => "deadbeef",
        "before" => "0000000",
        "repository" => %{"full_name" => "octo/repo"},
        "pusher" => %{"name" => "octocat"},
        "sender" => %{"login" => "octocat-sender"}
      }

      assert {:ok, %GithubContext{} = context} = GithubContext.from_event("push", event)

      assert context.event_name == "push"
      assert context.ref == "refs/heads/main"
      assert context.sha == "deadbeef"
      assert context.repository == "octo/repo"
      assert context.actor == "octocat"
      assert context.event == event
    end

    test "falls back to sender.login when pusher is absent" do
      event = %{
        "ref" => "refs/heads/main",
        "after" => "deadbeef",
        "repository" => %{"full_name" => "octo/repo"},
        "sender" => %{"login" => "octocat-sender"}
      }

      assert {:ok, %GithubContext{actor: "octocat-sender"}} =
               GithubContext.from_event("push", event)
    end
  end

  describe "from_event/2 — pull_request" do
    test "derives the synthetic merge ref and the PR head sha" do
      event = %{
        "number" => 42,
        "pull_request" => %{"head" => %{"sha" => "feedface"}},
        "repository" => %{"full_name" => "octo/repo"},
        "sender" => %{"login" => "contributor"}
      }

      assert {:ok, %GithubContext{} = context} = GithubContext.from_event("pull_request", event)

      assert context.ref == "refs/pull/42/merge"
      assert context.sha == "feedface"
      assert context.repository == "octo/repo"
      assert context.actor == "contributor"
    end

    test "pull_request_target uses the same derivation as pull_request" do
      event = %{
        "number" => 7,
        "pull_request" => %{"head" => %{"sha" => "cafed00d"}},
        "repository" => %{"full_name" => "octo/repo"},
        "sender" => %{"login" => "contributor"}
      }

      assert {:ok, %GithubContext{ref: "refs/pull/7/merge", sha: "cafed00d"}} =
               GithubContext.from_event("pull_request_target", event)
    end
  end

  describe "from_event/2 — fallback (workflow_dispatch, schedule, release, ...)" do
    test "workflow_dispatch reads top-level ref/sha and sender.login" do
      event = %{
        "ref" => "refs/heads/release",
        "sha" => "abc123",
        "repository" => %{"full_name" => "octo/repo"},
        "sender" => %{"login" => "operator"}
      }

      assert {:ok, %GithubContext{} = context} =
               GithubContext.from_event("workflow_dispatch", event)

      assert context.ref == "refs/heads/release"
      assert context.sha == "abc123"
      assert context.actor == "operator"
    end

    test "an event with no ref/sha/repository/sender defaults every derived field to empty" do
      assert {:ok, %GithubContext{} = context} = GithubContext.from_event("schedule", %{})

      assert context.ref == ""
      assert context.sha == ""
      assert context.repository == ""
      assert context.actor == ""
      assert context.event == %{}
    end
  end

  describe "from_event/2 determinism" do
    test "identical (event_name, event) input always yields a byte-identical context" do
      event = %{
        "ref" => "refs/heads/main",
        "after" => "deadbeef",
        "repository" => %{"full_name" => "octo/repo"},
        "pusher" => %{"name" => "octocat"}
      }

      assert GithubContext.from_event("push", event) == GithubContext.from_event("push", event)
    end
  end

  describe "wire round-trip" do
    test "to_wire/1 then from_wire/1 reproduces the original context" do
      {:ok, context} =
        GithubContext.new(%{
          actor: "octocat",
          event: %{"action" => "opened"},
          event_name: "pull_request",
          ref: "refs/pull/1/merge",
          repository: "octo/repo",
          sha: "abc123"
        })

      assert {:ok, ^context} = context |> GithubContext.to_wire() |> GithubContext.from_wire()
    end

    test "to_wire/1 uses camelCase keys" do
      {:ok, context} =
        GithubContext.new(%{
          actor: "octocat",
          event: %{},
          event_name: "push",
          ref: "refs/heads/main",
          repository: "octo/repo",
          sha: "abc123"
        })

      assert GithubContext.to_wire(context) == %{
               "actor" => "octocat",
               "event" => %{},
               "eventName" => "push",
               "ref" => "refs/heads/main",
               "repository" => "octo/repo",
               "sha" => "abc123"
             }
    end

    test "from_wire/1 rejects a non-map argument" do
      assert {:error, {:invalid_github_context, "nope"}} = GithubContext.from_wire("nope")
    end
  end

  describe "to_expr_context/1" do
    test "produces GitHub's own property names, including snake_case event_name" do
      {:ok, context} =
        GithubContext.new(%{
          actor: "octocat",
          event: %{"action" => "opened"},
          event_name: "pull_request",
          ref: "refs/pull/1/merge",
          repository: "octo/repo",
          sha: "abc123"
        })

      assert GithubContext.to_expr_context(context) == %{
               "actor" => "octocat",
               "event" => %{"action" => "opened"},
               "event_name" => "pull_request",
               "ref" => "refs/pull/1/merge",
               "repository" => "octo/repo",
               "sha" => "abc123"
             }
    end
  end

  describe "Jason.Encoder" do
    test "encodes via the wire shape" do
      {:ok, context} =
        GithubContext.new(%{
          actor: "octocat",
          event: %{},
          event_name: "push",
          ref: "refs/heads/main",
          repository: "octo/repo",
          sha: "abc123"
        })

      encoded = Jason.encode!(context)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded == GithubContext.to_wire(context)
    end
  end
end
