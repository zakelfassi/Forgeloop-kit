defmodule ForgeloopV2.ServiceContract do
  @moduledoc false

  @contract_name "forgeloop_loopback"
  @contract_version 1
  @schema_path "/api/schema"

  @payload_versions %{
    overview: 1,
    events: 1,
    events_meta: 1,
    coordination: 1,
    tracker: 1,
    workflow_overview: 1,
    provider_health: 1,
    babysitter: 1,
    runtime_owner: 1
  }

  @endpoints %{
    health: %{path: "/health"},
    schema: %{path: @schema_path},
    overview: %{path: "/api/overview"},
    providers: %{path: "/api/providers"},
    runtime: %{path: "/api/runtime"},
    backlog: %{path: "/api/backlog"},
    tracker: %{path: "/api/tracker"},
    questions: %{
      path: "/api/questions",
      answer_path_template: "/api/questions/{question_id}/answer",
      resolve_path_template: "/api/questions/{question_id}/resolve"
    },
    escalations: %{path: "/api/escalations"},
    events: %{path: "/api/events"},
    coordination: %{path: "/api/coordination", payload_version: 1},
    workflows: %{
      path: "/api/workflows",
      fetch_path_template: "/api/workflows/{workflow_name}",
      preflight_path_template: "/api/workflows/{workflow_name}/preflight",
      run_path_template: "/api/workflows/{workflow_name}/run"
    },
    control: %{
      pause_path: "/api/control/pause",
      clear_pause_path: "/api/control/clear-pause",
      replan_path: "/api/control/replan",
      run_path: "/api/control/run"
    },
    babysitter: %{
      path: "/api/babysitter",
      start_path: "/api/babysitter/start",
      stop_path: "/api/babysitter/stop"
    },
    stream: %{
      path: "/api/stream",
      snapshot_event: "snapshot",
      data_event: "event"
    }
  }

  def api_metadata do
    %{
      name: @contract_name,
      contract_version: @contract_version,
      schema_path: @schema_path
    }
  end

  def descriptor do
    %{
      contract_name: @contract_name,
      contract_version: @contract_version,
      payload_versions: @payload_versions,
      endpoints: @endpoints
    }
  end

  def wrap_envelope(payload) when is_map(payload) do
    Map.put_new(payload, :api, api_metadata())
  end
end
