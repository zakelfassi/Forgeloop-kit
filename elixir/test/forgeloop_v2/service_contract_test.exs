defmodule ForgeloopV2.ServiceContractTest do
  use ExUnit.Case, async: true

  alias ForgeloopV2.ServiceContract

  test "descriptor exposes the versioned loopback contract" do
    api = ServiceContract.api_metadata()
    descriptor = ServiceContract.descriptor()

    assert api == %{
             name: "forgeloop_loopback",
             contract_version: 1,
             schema_path: "/api/schema"
           }

    assert descriptor.contract_name == "forgeloop_loopback"
    assert descriptor.contract_version == 1
    assert descriptor.payload_versions.overview == 1
    assert descriptor.payload_versions.events == 1
    assert descriptor.payload_versions.events_meta == 1
    assert descriptor.payload_versions.coordination == 1
    assert descriptor.payload_versions.tracker == 1
    assert descriptor.payload_versions.workflow_overview == 1
    assert descriptor.payload_versions.provider_health == 1
    assert descriptor.payload_versions.babysitter == 1
    assert descriptor.payload_versions.runtime_owner == 1
    assert descriptor.endpoints.schema.path == "/api/schema"
    assert descriptor.endpoints.overview.path == "/api/overview"
    assert descriptor.endpoints.events.path == "/api/events"
    assert descriptor.endpoints.coordination.path == "/api/coordination"
    assert descriptor.endpoints.coordination.payload_version == 1
    assert descriptor.endpoints.questions.answer_path_template == "/api/questions/{question_id}/answer"
    assert descriptor.endpoints.questions.resolve_path_template == "/api/questions/{question_id}/resolve"
    assert descriptor.endpoints.workflows.fetch_path_template == "/api/workflows/{workflow_name}"
    assert descriptor.endpoints.workflows.preflight_path_template == "/api/workflows/{workflow_name}/preflight"
    assert descriptor.endpoints.workflows.run_path_template == "/api/workflows/{workflow_name}/run"
    assert descriptor.endpoints.control.pause_path == "/api/control/pause"
    assert descriptor.endpoints.control.clear_pause_path == "/api/control/clear-pause"
    assert descriptor.endpoints.control.replan_path == "/api/control/replan"
    assert descriptor.endpoints.control.run_path == "/api/control/run"
    assert descriptor.endpoints.babysitter.start_path == "/api/babysitter/start"
    assert descriptor.endpoints.babysitter.stop_path == "/api/babysitter/stop"
    assert descriptor.endpoints.stream.path == "/api/stream"
    assert descriptor.endpoints.stream.snapshot_event == "snapshot"
    assert descriptor.endpoints.stream.data_event == "event"
  end

  test "wrap_envelope adds additive api metadata once" do
    payload = %{ok: true, data: %{hello: "world"}}

    assert ServiceContract.wrap_envelope(payload).api == ServiceContract.api_metadata()

    existing = %{ok: true, api: %{name: "custom", contract_version: 99}, data: %{}}
    assert ServiceContract.wrap_envelope(existing).api == existing.api
  end
end
