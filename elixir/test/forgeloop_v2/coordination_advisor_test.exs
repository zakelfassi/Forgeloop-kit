defmodule ForgeloopV2.CoordinationAdvisorTest do
  use ForgeloopV2.TestSupport

  alias ForgeloopV2.CoordinationAdvisor

  test "actionable rebuild playbook dedupes duplicate events and exposes counts" do
    snapshot = %{
      runtime_state: %{status: "running"},
      backlog: %{needs_build?: true},
      control_flags: %{pause_requested?: false, replan_requested?: false},
      questions: [],
      babysitter: %{running?: false},
      events: [
        %{
          "event_id" => "evt-1",
          "event_code" => "daemon_tick",
          "occurred_at" => "2026-03-21T00:59:00Z",
          "action" => "build",
          "reason" => "Backlog still needs work."
        },
        %{
          "event_id" => "evt-2",
          "event_code" => "operator_action",
          "occurred_at" => "2026-03-21T01:00:00Z",
          "action" => "clear_pause"
        },
        %{
          "event_id" => "evt-2",
          "event_code" => "operator_action",
          "occurred_at" => "2026-03-21T01:00:00Z",
          "action" => "clear_pause"
        },
        %{
          "event_id" => "evt-3",
          "event_code" => "operator_action",
          "occurred_at" => "2026-03-21T01:01:00Z",
          "action" => "clear_pause"
        }
      ],
      events_meta: %{
        "latest_event_id" => "evt-3",
        "returned_count" => 4,
        "limit" => 9,
        "cursor_found?" => true,
        "truncated?" => false
      }
    }

    assert {:ok, result} = CoordinationAdvisor.evaluate_snapshot(snapshot, after: "evt-0")

    assert result.status == "actionable"
    assert result.event_source == "events_api"
    assert result.cursor.next_after == "evt-3"
    assert result.summary.fetched_events == 4
    assert result.summary.unique_events == 3
    assert result.summary.duplicate_events == 1
    assert result.brief =~ "Actionable: Queue the next rebuild pass"

    assert Enum.map(result.timeline, & &1.kind) == [
             "daemon_decision",
             "operator_action",
             "operator_action"
           ]

    assert List.first(result.timeline).title == "Daemon decided Build"
    assert List.last(result.timeline).related_playbook_ids == ["post_clear_pause_rebuild"]
    assert result.summary.recommendations == 1
    assert result.summary.playbooks.total == 1
    assert result.summary.playbooks.actionable == 1
    assert hd(result.recommendations).rule == "replan_after_clear_pause"
    assert hd(result.playbooks).id == "post_clear_pause_rebuild"
    assert hd(result.playbooks).recommended_action == "replan"
    assert hd(result.playbooks).steps |> hd() |> Map.fetch!(:action) == "replan"
  end

  test "blocked human answer recovery playbook preserves blocker reasons" do
    snapshot = %{
      runtime_state: %{status: "paused"},
      backlog: %{needs_build?: true},
      control_flags: %{pause_requested?: true, replan_requested?: false},
      questions: [%{id: "Q-1", status_kind: "awaiting_response"}],
      babysitter: %{running?: false},
      events: [
        %{
          "event_id" => "evt-answer",
          "event_code" => "operator_action",
          "occurred_at" => "2026-03-21T01:30:00Z",
          "action" => "answer_question"
        }
      ],
      events_meta: %{
        "latest_event_id" => "evt-answer",
        "returned_count" => 1,
        "limit" => 6,
        "cursor_found?" => true,
        "truncated?" => false
      }
    }

    assert {:ok, result} =
             CoordinationAdvisor.evaluate_snapshot(snapshot,
               after: "evt-prev",
               playbook_id: "human_answer_recovery"
             )

    assert result.status == "blocked"
    assert result.selected_playbook_id == "human_answer_recovery"
    assert result.brief =~ "Blocked: Resume after human answers land"
    assert hd(result.timeline).kind == "operator_action"
    assert hd(result.timeline).related_playbook_ids == ["human_answer_recovery"]
    assert hd(result.playbooks).status == "blocked"
    assert hd(result.playbooks).recommended_action == "clear_pause"
    assert "unanswered_questions_remain" in hd(result.playbooks).blocked_by
    assert hd(result.playbooks).steps |> hd() |> Map.fetch!(:apply_eligible) == false
  end

  test "failure stabilization can settle into observe state" do
    snapshot = %{
      runtime_state: %{status: "paused"},
      backlog: %{needs_build?: true},
      control_flags: %{pause_requested?: true, replan_requested?: false},
      questions: [],
      babysitter: %{running?: false},
      events: [
        %{
          "event_id" => "evt-fail",
          "event_code" => "loop_failed",
          "occurred_at" => "2026-03-21T01:45:00Z"
        }
      ],
      events_meta: %{
        "latest_event_id" => "evt-fail",
        "returned_count" => 1,
        "limit" => 6,
        "cursor_found?" => true,
        "truncated?" => false
      }
    }

    assert {:ok, result} =
             CoordinationAdvisor.evaluate_snapshot(snapshot,
               after: "evt-prev",
               playbook_id: "failure_stabilization"
             )

    assert result.status == "observe"
    assert result.brief =~ "Observe: Stabilize after a failure signal"
    assert hd(result.timeline).kind == "failure_signal"
    assert hd(result.timeline).title == "Managed run failed"
    assert hd(result.playbooks).status == "observe"
    assert hd(result.playbooks).recommended_action == nil
    assert hd(result.playbooks).steps |> hd() |> Map.fetch!(:kind) == "manual"
  end

  test "missing cursors and absent selected playbooks fail soft with warnings" do
    snapshot = %{
      runtime_state: %{status: "running"},
      backlog: %{needs_build?: true},
      control_flags: %{pause_requested?: false, replan_requested?: false},
      questions: [],
      babysitter: %{running?: false},
      events: [],
      events_meta: %{
        "latest_event_id" => "evt-9",
        "returned_count" => 0,
        "limit" => 5,
        "cursor_found?" => false,
        "truncated?" => false
      }
    }

    assert {:ok, result} =
             CoordinationAdvisor.evaluate_snapshot(snapshot,
               after: "stale-cursor",
               playbook_id: "human_answer_recovery"
             )

    assert result.status == "idle"
    assert result.brief =~ "Partial context"
    assert result.timeline == []
    assert result.cursor.next_after == "evt-9"
    assert result.cursor.reset_required == true
    assert result.recommendations == []
    assert result.playbooks == []

    assert result.warnings == [
             "cursor_not_found_reset_required",
             "selected_playbook_not_triggered"
           ]
  end

  test "invalid playbook ids are rejected" do
    assert {:error, {:invalid_coordination_playbook, "nope"}} =
             CoordinationAdvisor.evaluate_snapshot(%{}, playbook_id: "nope")
  end
end
