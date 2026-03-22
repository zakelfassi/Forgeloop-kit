defmodule ForgeloopV2.CoordinationAdvisor.Result do
  @moduledoc false

  defstruct [
    :schema_version,
    :status,
    :selected_playbook_id,
    :event_source,
    :cursor,
    :summary,
    recommendations: [],
    playbooks: [],
    warnings: []
  ]
end

defmodule ForgeloopV2.CoordinationAdvisor.Cursor do
  @moduledoc false

  defstruct [
    :requested_after,
    :next_after,
    :cursor_found,
    truncated: false,
    reset_required: false
  ]
end

defmodule ForgeloopV2.CoordinationAdvisor.PlaybookCounts do
  @moduledoc false

  defstruct total: 0, actionable: 0, blocked: 0, observe: 0
end

defmodule ForgeloopV2.CoordinationAdvisor.Summary do
  @moduledoc false

  defstruct fetched_events: 0,
            unique_events: 0,
            duplicate_events: 0,
            actionable_events: 0,
            recommendations: 0,
            playbooks: %ForgeloopV2.CoordinationAdvisor.PlaybookCounts{}
end

defmodule ForgeloopV2.CoordinationAdvisor.Recommendation do
  @moduledoc false

  defstruct [
    :rule,
    :action,
    :playbook_id,
    :event_id,
    :event_code,
    :event_action,
    :event_occurred_at,
    :reason,
    apply_eligible: false,
    blocked_by: []
  ]
end

defmodule ForgeloopV2.CoordinationAdvisor.Playbook do
  @moduledoc false

  defstruct [
    :id,
    :title,
    :goal,
    :status,
    :reason,
    :recommended_action,
    evidence: [],
    apply_eligible: false,
    blocked_by: [],
    steps: []
  ]
end

defmodule ForgeloopV2.CoordinationAdvisor do
  @moduledoc false

  alias __MODULE__.{Cursor, Playbook, PlaybookCounts, Recommendation, Result, Summary}

  @playbook_ids ["human_answer_recovery", "post_clear_pause_rebuild", "failure_stabilization"]
  @failure_event_codes MapSet.new([
                         "loop_failed",
                         "babysitter_failed",
                         "daemon_deploy_failed",
                         "daemon_ingest_logs_failed"
                       ])

  @type snapshot :: map()

  @spec playbook_ids() :: [String.t()]
  def playbook_ids, do: @playbook_ids

  @spec evaluate_snapshot(snapshot(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def evaluate_snapshot(snapshot, opts \\ []) when is_map(snapshot) do
    with {:ok, playbook_id} <- normalize_playbook_id(Keyword.get(opts, :playbook_id)) do
      after_cursor = normalize_cursor(Keyword.get(opts, :after))
      events = map_value(snapshot, :events, "events") || []
      meta = normalize_events_meta(map_value(snapshot, :events_meta, "events_meta"))
      deduped = dedupe_events(events)
      recommendations = evaluate_recommendations(deduped.unique, snapshot, playbook_id)
      playbooks = build_playbooks(recommendations)
      cursor = build_cursor(meta, after_cursor, deduped.unique)

      {:ok,
       %Result{
         schema_version: 1,
         status: coordination_status(playbooks),
         selected_playbook_id: playbook_id,
         event_source: "events_api",
         cursor: cursor,
         summary: %Summary{
           fetched_events: deduped.total,
           unique_events: length(deduped.unique),
           duplicate_events: deduped.duplicates,
           actionable_events: count_actionable_events(deduped.unique),
           recommendations: length(recommendations),
           playbooks: summarize_playbooks(playbooks)
         },
         recommendations: recommendations,
         playbooks: playbooks,
         warnings: warnings_for(cursor, playbook_id, playbooks)
       }}
    end
  end

  defp rules do
    [
      %{
        id: "clear_pause_after_human_answer",
        action: "clear_pause",
        playbook_id: "human_answer_recovery",
        playbook_title: "Resume after human answers land",
        playbook_goal:
          "Clear a stale pause once human answers have landed and no unanswered questions remain.",
        observe_blocked_reasons: ["pause_not_requested", "runtime_not_paused"]
      },
      %{
        id: "replan_after_clear_pause",
        action: "replan",
        playbook_id: "post_clear_pause_rebuild",
        playbook_title: "Queue the next rebuild pass",
        playbook_goal:
          "Request a new plan/build pass after pause is cleared when canonical backlog work is still pending.",
        observe_blocked_reasons: ["backlog_not_ready", "replan_already_requested"]
      },
      %{
        id: "pause_after_failure_signal",
        action: "pause",
        playbook_id: "failure_stabilization",
        playbook_title: "Stabilize after a failure signal",
        playbook_goal:
          "Pause the control plane after a fresh failure signal so the operator can review evidence before more work starts.",
        observe_blocked_reasons: ["pause_already_requested", "runtime_already_blocked"]
      }
    ]
  end

  defp evaluate_recommendations(events, snapshot, playbook_id) do
    newest_first = Enum.reverse(events)

    rules()
    |> Enum.reduce([], fn rule, acc ->
      case Enum.find(newest_first, &matches_rule?(rule.id, &1)) do
        nil ->
          acc

        event ->
          recommendation = recommendation(rule, event, snapshot)

          if is_nil(playbook_id) or recommendation.playbook_id == playbook_id do
            acc ++ [recommendation]
          else
            acc
          end
      end
    end)
  end

  defp recommendation(rule, event, snapshot) do
    blocked_by = blocked_by(rule.id, event, snapshot)

    %Recommendation{
      rule: rule.id,
      action: rule.action,
      playbook_id: rule.playbook_id,
      event_id: normalize_cursor(map_value(event, :event_id, "event_id")),
      event_code: event_code(event),
      event_action: normalize_cursor(map_value(event, :action, "action")),
      event_occurred_at: event_timestamp(event),
      reason: reason(rule.id, event),
      apply_eligible: blocked_by == [],
      blocked_by: blocked_by
    }
  end

  defp build_playbooks(recommendations) do
    Enum.map(recommendations, fn recommendation ->
      rule = Enum.find(rules(), &(&1.id == recommendation.rule))
      status = playbook_status(rule, recommendation.blocked_by)
      recommended_action = if status == "observe", do: nil, else: recommendation.action

      %Playbook{
        id: rule.playbook_id,
        title: rule.playbook_title,
        goal: rule.playbook_goal,
        status: status,
        reason: playbook_reason(rule, recommendation, status),
        evidence: [
          %{
            event_id: recommendation.event_id,
            event_code: recommendation.event_code,
            occurred_at: recommendation.event_occurred_at,
            action: recommendation.event_action
          }
        ],
        recommended_action: recommended_action,
        apply_eligible: recommendation.apply_eligible,
        blocked_by: recommendation.blocked_by,
        steps: build_steps(rule.id, recommendation, recommended_action)
      }
    end)
  end

  defp build_steps(_rule_id, recommendation, nil) do
    manual_steps_for(recommendation.rule, recommendation)
  end

  defp build_steps(rule_id, recommendation, recommended_action) do
    [
      control_step(rule_id, recommendation, recommended_action)
      | manual_steps_for(recommendation.rule, recommendation)
    ]
  end

  defp control_step("clear_pause_after_human_answer", recommendation, recommended_action) do
    %{
      kind: "control_action",
      title: "Clear the pause request",
      detail:
        "Clear pause so Forgeloop can resume normal operation after the human response is captured.",
      action: recommended_action,
      apply_eligible: recommendation.apply_eligible,
      blocked_by: recommendation.blocked_by
    }
  end

  defp control_step("replan_after_clear_pause", recommendation, recommended_action) do
    %{
      kind: "control_action",
      title: "Request replan",
      detail:
        "Queue one bounded replan so the managed control plane can pick up the next backlog pass.",
      action: recommended_action,
      apply_eligible: recommendation.apply_eligible,
      blocked_by: recommendation.blocked_by
    }
  end

  defp control_step("pause_after_failure_signal", recommendation, recommended_action) do
    %{
      kind: "control_action",
      title: "Pause the control plane",
      detail:
        "Write one canonical pause request so the runtime stops advancing while the failure is reviewed.",
      action: recommended_action,
      apply_eligible: recommendation.apply_eligible,
      blocked_by: recommendation.blocked_by
    }
  end

  defp manual_steps_for("clear_pause_after_human_answer", recommendation) do
    [
      %{
        kind: "manual",
        title: "Verify unanswered questions are cleared",
        detail:
          if("unanswered_questions_remain" in recommendation.blocked_by,
            do: "Answer or resolve the remaining canonical questions before clearing pause.",
            else: "Confirm QUESTIONS.md and the HUD show no remaining unanswered questions."
          )
      },
      %{
        kind: "manual",
        title: "Wait for active managed runs to settle",
        detail:
          if("babysitter_running" in recommendation.blocked_by,
            do:
              "A babysitter-managed run is still active. Let it finish or stop it before clearing pause.",
            else:
              "If a managed run restarts immediately, verify its babysitter state before intervening again."
          )
      }
    ]
  end

  defp manual_steps_for("replan_after_clear_pause", recommendation) do
    [
      %{
        kind: "manual",
        title: "Confirm the canonical backlog still needs a build",
        detail:
          if("backlog_not_ready" in recommendation.blocked_by,
            do:
              "IMPLEMENTATION_PLAN.md no longer signals pending phase-1 work, so observe instead of queuing another run.",
            else:
              "Verify IMPLEMENTATION_PLAN.md still reflects work that should trigger a new build pass."
          )
      },
      %{
        kind: "manual",
        title: "Avoid overlapping managed runs",
        detail:
          if("babysitter_running" in recommendation.blocked_by,
            do:
              "A babysitter-managed run is already active. Let it finish before queuing another replan.",
            else: "Keep the next run reviewable; do not stack multiple rebuild requests."
          )
      }
    ]
  end

  defp manual_steps_for("pause_after_failure_signal", recommendation) do
    [
      %{
        kind: "manual",
        title: "Inspect failure evidence",
        detail:
          "Review the latest failure artifacts and event trail for #{recommendation.event_code || "the failure signal"} before resuming."
      },
      %{
        kind: "manual",
        title: "Avoid interrupting an active babysitter run",
        detail:
          if("babysitter_running" in recommendation.blocked_by,
            do:
              "A babysitter-managed run is still active. Stop or let it settle before pausing again.",
            else:
              "If a managed run is already stopping, wait for it to finish before taking more action."
          )
      }
    ]
  end

  defp summarize_playbooks(playbooks) do
    %PlaybookCounts{
      total: length(playbooks),
      actionable: Enum.count(playbooks, &(&1.status == "actionable")),
      blocked: Enum.count(playbooks, &(&1.status == "blocked")),
      observe: Enum.count(playbooks, &(&1.status == "observe"))
    }
  end

  defp coordination_status(playbooks) do
    cond do
      Enum.any?(playbooks, &(&1.status == "actionable")) -> "actionable"
      Enum.any?(playbooks, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(playbooks, &(&1.status == "observe")) -> "observe"
      true -> "idle"
    end
  end

  defp playbook_reason(_rule, recommendation, "actionable"), do: recommendation.reason

  defp playbook_reason(rule, recommendation, "observe") do
    "#{rule.playbook_title} is already satisfied or safely waiting: #{describe_blocked_reasons(recommendation.blocked_by)}."
  end

  defp playbook_reason(rule, recommendation, _status) do
    "#{rule.playbook_title} is currently blocked by: #{describe_blocked_reasons(recommendation.blocked_by)}."
  end

  defp describe_blocked_reasons([]), do: "no blockers"

  defp describe_blocked_reasons(blocked_by),
    do: blocked_by |> Enum.map(&String.replace(&1, "_", " ")) |> Enum.join(", ")

  defp playbook_status(_rule, []), do: "actionable"

  defp playbook_status(rule, blocked_by) do
    if Enum.all?(blocked_by, &(&1 in rule.observe_blocked_reasons)) do
      "observe"
    else
      "blocked"
    end
  end

  defp warnings_for(cursor, playbook_id, playbooks) do
    []
    |> maybe_warn(cursor.cursor_found == false, "cursor_not_found_reset_required")
    |> maybe_warn(
      cursor.truncated == true and not is_nil(cursor.requested_after),
      "replay_truncated_reset_required"
    )
    |> maybe_warn(not is_nil(playbook_id) and playbooks == [], "selected_playbook_not_triggered")
  end

  defp maybe_warn(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_warn(warnings, false, _warning), do: warnings

  defp build_cursor(meta, requested_after, unique_events) do
    cursor_found = if requested_after, do: meta.cursor_found, else: nil
    truncated = if requested_after, do: meta.truncated, else: meta.truncated

    %Cursor{
      requested_after: requested_after,
      next_after: meta.latest_event_id || latest_event_id(unique_events),
      cursor_found: cursor_found,
      truncated: truncated,
      reset_required: not is_nil(requested_after) and (cursor_found == false or truncated == true)
    }
  end

  defp normalize_events_meta(meta) when is_map(meta) do
    %{
      latest_event_id: normalize_cursor(map_value(meta, :latest_event_id, "latest_event_id")),
      returned_count: map_value(meta, :returned_count, "returned_count") || 0,
      limit: map_value(meta, :limit, "limit") || 0,
      cursor_found:
        nullable_boolean(map_value(meta, :cursor_found?, "cursor_found?", "cursor_found")),
      truncated:
        nullable_boolean(map_value(meta, :truncated?, "truncated?", "truncated")) || false
    }
  end

  defp normalize_events_meta(_),
    do: %{latest_event_id: nil, returned_count: 0, limit: 0, cursor_found: nil, truncated: false}

  defp dedupe_events(events) when is_list(events) do
    {unique, _seen, duplicates} =
      Enum.reduce(events, {[], MapSet.new(), 0}, fn event, {acc, seen, duplicates} ->
        case normalize_cursor(map_value(event, :event_id, "event_id")) do
          nil ->
            {acc ++ [event], seen, duplicates}

          event_id ->
            if MapSet.member?(seen, event_id) do
              {acc, seen, duplicates + 1}
            else
              {acc ++ [event], MapSet.put(seen, event_id), duplicates}
            end
        end
      end)

    %{total: length(events), duplicates: duplicates, unique: unique}
  end

  defp dedupe_events(_), do: %{total: 0, duplicates: 0, unique: []}

  defp count_actionable_events(events) do
    Enum.count(events, fn event ->
      normalize_cursor(map_value(event, :event_id, "event_id")) &&
        Enum.any?(rules(), &matches_rule?(&1.id, event))
    end)
  end

  defp latest_event_id(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event -> normalize_cursor(map_value(event, :event_id, "event_id")) end)
  end

  defp matches_rule?("clear_pause_after_human_answer", event) do
    event_code(event) == "operator_action" and
      map_value(event, :action, "action") in ["answer_question", "resolve_question"]
  end

  defp matches_rule?("replan_after_clear_pause", event) do
    event_code(event) == "operator_action" and
      map_value(event, :action, "action") == "clear_pause"
  end

  defp matches_rule?("pause_after_failure_signal", event) do
    MapSet.member?(@failure_event_codes, event_code(event))
  end

  defp blocked_by("clear_pause_after_human_answer", _event, snapshot) do
    []
    |> maybe_block(not pause_requested?(snapshot), "pause_not_requested")
    |> maybe_block(not runtime_paused_or_awaiting_human?(snapshot), "runtime_not_paused")
    |> maybe_block(awaiting_question_count(snapshot) > 0, "unanswered_questions_remain")
    |> maybe_block(babysitter_running?(snapshot), "babysitter_running")
  end

  defp blocked_by("replan_after_clear_pause", _event, snapshot) do
    []
    |> maybe_block(not needs_build?(snapshot), "backlog_not_ready")
    |> maybe_block(replan_requested?(snapshot), "replan_already_requested")
    |> maybe_block(babysitter_running?(snapshot), "babysitter_running")
    |> maybe_block(runtime_status(snapshot) == "awaiting-human", "awaiting_human")
  end

  defp blocked_by("pause_after_failure_signal", _event, snapshot) do
    []
    |> maybe_block(pause_requested?(snapshot), "pause_already_requested")
    |> maybe_block(
      runtime_status(snapshot) in ["paused", "awaiting-human"],
      "runtime_already_blocked"
    )
    |> maybe_block(babysitter_running?(snapshot), "babysitter_running")
  end

  defp maybe_block(blocked_by, true, reason), do: blocked_by ++ [reason]
  defp maybe_block(blocked_by, false, _reason), do: blocked_by

  defp reason("clear_pause_after_human_answer", event) do
    "Question action #{map_value(event, :action, "action") || "unknown"} landed while pause is still requested and no unanswered questions remain."
  end

  defp reason("replan_after_clear_pause", _event) do
    "Pause was cleared while the backlog still needs a build and no replan is currently queued."
  end

  defp reason("pause_after_failure_signal", event) do
    "Failure signal #{event_code(event)} arrived while the runtime is still live."
  end

  defp pause_requested?(snapshot) do
    flags = map_value(snapshot, :control_flags, "control_flags") || %{}
    truthy?(map_value(flags, :pause_requested?, "pause_requested?", "pause_requested"))
  end

  defp replan_requested?(snapshot) do
    flags = map_value(snapshot, :control_flags, "control_flags") || %{}
    truthy?(map_value(flags, :replan_requested?, "replan_requested?", "replan_requested"))
  end

  defp needs_build?(snapshot) do
    backlog = map_value(snapshot, :backlog, "backlog") || %{}
    truthy?(map_value(backlog, :needs_build?, "needs_build?", "needs_build"))
  end

  defp awaiting_question_count(snapshot) do
    snapshot
    |> map_value(:questions, "questions")
    |> List.wrap()
    |> Enum.count(fn question ->
      map_value(question, :status_kind, "status_kind") in [
        "awaiting_response",
        :awaiting_response
      ]
    end)
  end

  defp runtime_status(snapshot) do
    runtime = map_value(snapshot, :runtime_state, "runtime_state") || %{}
    map_value(runtime, :status, "status") || "unknown"
  end

  defp runtime_paused_or_awaiting_human?(snapshot) do
    runtime_status(snapshot) in ["paused", "awaiting-human"]
  end

  defp babysitter_running?(snapshot) do
    babysitter = map_value(snapshot, :babysitter, "babysitter") || %{}
    truthy?(map_value(babysitter, :running?, "running?", "running"))
  end

  defp event_code(event) do
    map_value(event, :event_code, "event_code", "event_type") || "event"
  end

  defp event_timestamp(event) do
    map_value(event, :occurred_at, "occurred_at", "recorded_at")
  end

  defp normalize_playbook_id(nil), do: {:ok, nil}

  defp normalize_playbook_id(playbook_id) when is_binary(playbook_id) do
    normalized = normalize_cursor(playbook_id)

    cond do
      is_nil(normalized) -> {:error, {:invalid_coordination_playbook, playbook_id}}
      normalized in @playbook_ids -> {:ok, normalized}
      true -> {:error, {:invalid_coordination_playbook, playbook_id}}
    end
  end

  defp normalize_playbook_id(other), do: {:error, {:invalid_coordination_playbook, other}}

  defp normalize_cursor(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_cursor(_), do: nil

  defp nullable_boolean(value) when value in [true, false], do: value
  defp nullable_boolean(nil), do: nil
  defp nullable_boolean(value), do: !!value

  defp truthy?(value), do: value in [true, 1, "1", "true", "yes", "on"]

  defp map_value(map, key, fallback_key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, fallback_key) -> Map.get(map, fallback_key)
      true -> nil
    end
  end

  defp map_value(_, _key, _fallback_key), do: nil

  defp map_value(map, key, fallback_key, alternate_key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, fallback_key) -> Map.get(map, fallback_key)
      Map.has_key?(map, alternate_key) -> Map.get(map, alternate_key)
      true -> nil
    end
  end

  defp map_value(_, _key, _fallback_key, _alternate_key), do: nil
end
