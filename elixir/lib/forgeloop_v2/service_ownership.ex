defmodule ForgeloopV2.ServiceOwnership do
  @moduledoc false

  @spec evaluate(map() | nil, map() | nil) :: map()
  def evaluate(runtime_owner, babysitter) do
    runtime_owner_view = runtime_owner_view(runtime_owner)
    active_run_view = active_run_view(babysitter)
    gate = gate(runtime_owner || %{}, babysitter || %{}, runtime_owner_view, active_run_view)

    %{
      summary_state: summary_state(gate, runtime_owner_view, active_run_view),
      headline: headline(gate, runtime_owner_view, active_run_view),
      detail: detail(gate, runtime_owner_view, active_run_view),
      start_allowed?: gate.status == "allowed",
      conflict?: gate.conflict?,
      fail_closed?: gate.fail_closed?,
      start_gate: Map.delete(gate, :gate_error),
      runtime_owner: runtime_owner_view,
      active_run: active_run_view,
      gate_error: gate.gate_error
    }
  end

  defp gate(_runtime_owner, %{running?: true, managed?: true}, _runtime_owner_view, active_run_view) do
    %{
      status: "blocked",
      reason: "babysitter_already_running",
      http_status: 409,
      reclaim_on_start?: false,
      cleanup_on_start?: false,
      details: details_or_nil(active_run_view),
      conflict?: true,
      fail_closed?: false,
      gate_error: :babysitter_already_running
    }
  end

  defp gate(_runtime_owner, %{running?: true, active_run: active_run}, _runtime_owner_view, active_run_view) do
    payload = if is_map(active_run), do: active_run, else: %{}

    %{
      status: "blocked",
      reason: "babysitter_unmanaged_active",
      http_status: 409,
      reclaim_on_start?: false,
      cleanup_on_start?: false,
      details: details_or_nil(active_run_view),
      conflict?: true,
      fail_closed?: false,
      gate_error: {:babysitter_unmanaged_active, payload}
    }
  end

  defp gate(%{state: "error"} = runtime_owner, _babysitter, runtime_owner_view, _active_run_view) do
    %{
      status: "error",
      reason: "active_runtime_state_error",
      http_status: 500,
      reclaim_on_start?: false,
      cleanup_on_start?: false,
      details: details_or_nil(runtime_owner_view),
      conflict?: false,
      fail_closed?: true,
      gate_error: {:active_runtime_state_error, runtime_owner}
    }
  end

  defp gate(_runtime_owner, %{active_run_state: "error", active_run_error: error}, _runtime_owner_view, active_run_view) do
    %{
      status: "error",
      reason: "active_run_state_error",
      http_status: 500,
      reclaim_on_start?: false,
      cleanup_on_start?: false,
      details: details_or_nil(active_run_view),
      conflict?: false,
      fail_closed?: true,
      gate_error: {:active_run_state_error, error}
    }
  end

  defp gate(%{live?: true, current: current}, _babysitter, runtime_owner_view, _active_run_view)
       when is_map(current) do
    %{
      status: "blocked",
      reason: "active_runtime_owned_by",
      http_status: 409,
      reclaim_on_start?: false,
      cleanup_on_start?: false,
      details: details_or_nil(runtime_owner_view),
      conflict?: true,
      fail_closed?: false,
      gate_error: {:active_runtime_owned_by, current}
    }
  end

  defp gate(_runtime_owner, _babysitter, runtime_owner_view, active_run_view) do
    %{
      status: "allowed",
      reason: nil,
      http_status: nil,
      reclaim_on_start?: runtime_owner_view.reclaimable?,
      cleanup_on_start?: active_run_view.state == "stale",
      details: nil,
      conflict?: false,
      fail_closed?: false,
      gate_error: nil
    }
  end

  defp runtime_owner_view(owner) when is_map(owner) do
    current = Map.get(owner, :current) || Map.get(owner, "current") || %{}

    %{
      state: Map.get(owner, :state) || Map.get(owner, "state") || "missing",
      owner: current["owner"] || current[:owner],
      surface: current["surface"] || current[:surface],
      mode: current["mode"] || current[:mode],
      branch: current["branch"] || current[:branch],
      claim_id: current["claim_id"] || current[:claim_id],
      reclaimable?: truthy?(Map.get(owner, :reclaimable?) || Map.get(owner, "reclaimable?")),
      error: Map.get(owner, :error) || Map.get(owner, "error")
    }
  end

  defp runtime_owner_view(_owner) do
    %{
      state: "missing",
      owner: nil,
      surface: nil,
      mode: nil,
      branch: nil,
      claim_id: nil,
      reclaimable?: false,
      error: nil
    }
  end

  defp active_run_view(babysitter) when is_map(babysitter) do
    active_run = Map.get(babysitter, :active_run) || Map.get(babysitter, "active_run") || %{}

    %{
      state: Map.get(babysitter, :active_run_state) || Map.get(babysitter, "active_run_state") || "missing",
      managed?: truthy?(Map.get(babysitter, :managed?) || Map.get(babysitter, "managed?")),
      running?: truthy?(Map.get(babysitter, :running?) || Map.get(babysitter, "running?")),
      lane: Map.get(babysitter, :lane) || Map.get(babysitter, "lane") || active_run["lane"] || active_run[:lane],
      action: Map.get(babysitter, :action) || Map.get(babysitter, "action") || active_run["action"] || active_run[:action],
      mode: Map.get(babysitter, :mode) || Map.get(babysitter, "mode") || active_run["mode"] || active_run[:mode],
      workflow_name:
        Map.get(babysitter, :workflow_name) ||
          Map.get(babysitter, "workflow_name") ||
          active_run["workflow_name"] ||
          active_run[:workflow_name],
      branch: Map.get(babysitter, :branch) || Map.get(babysitter, "branch") || active_run["branch"] || active_run[:branch],
      runtime_surface:
        Map.get(babysitter, :runtime_surface) ||
          Map.get(babysitter, "runtime_surface") ||
          active_run["runtime_surface"] ||
          active_run[:runtime_surface],
      error: Map.get(babysitter, :active_run_error) || Map.get(babysitter, "active_run_error")
    }
  end

  defp active_run_view(_babysitter) do
    %{
      state: "missing",
      managed?: false,
      running?: false,
      lane: nil,
      action: nil,
      mode: nil,
      workflow_name: nil,
      branch: nil,
      runtime_surface: nil,
      error: nil
    }
  end

  defp summary_state(%{status: "error"}, _runtime_owner_view, _active_run_view), do: "error"
  defp summary_state(%{status: "blocked"}, _runtime_owner_view, _active_run_view), do: "blocked"

  defp summary_state(gate, runtime_owner_view, active_run_view) do
    if gate.reclaim_on_start? || gate.cleanup_on_start? || runtime_owner_view.reclaimable? || active_run_view.state == "stale" do
      "recoverable"
    else
      "ready"
    end
  end

  defp headline(%{status: "error", reason: "active_runtime_state_error"}, _runtime_owner_view, _active_run_view),
    do: "Runtime ownership metadata is malformed"

  defp headline(%{status: "error", reason: "active_run_state_error"}, _runtime_owner_view, _active_run_view),
    do: "Managed run metadata is malformed"

  defp headline(%{status: "blocked", reason: "babysitter_already_running"}, _runtime_owner_view, _active_run_view),
    do: "A managed babysitter run is already active"

  defp headline(%{status: "blocked", reason: "babysitter_unmanaged_active"}, _runtime_owner_view, _active_run_view),
    do: "Unmanaged active-run metadata is blocking new starts"

  defp headline(%{status: "blocked", reason: "active_runtime_owned_by"}, runtime_owner_view, _active_run_view) do
    owner = runtime_owner_view.owner || "another runtime"
    "Runtime ownership is currently held by #{owner}"
  end

  defp headline(_gate, runtime_owner_view, active_run_view) do
    cond do
      runtime_owner_view.reclaimable? and active_run_view.state == "stale" ->
        "A stale claim and stale managed-run metadata can be recovered"

      runtime_owner_view.reclaimable? ->
        "A stale runtime claim can be reclaimed on the next start"

      active_run_view.state == "stale" ->
        "Stale managed-run metadata will be cleaned before launch"

      true ->
        "Manual starts are currently clear"
    end
  end

  defp detail(%{status: "error", reason: "active_runtime_state_error"}, runtime_owner_view, _active_run_view) do
    "Starts fail closed until #{runtime_owner_view.error || "the malformed active-runtime claim"} is repaired or removed."
  end

  defp detail(%{status: "error", reason: "active_run_state_error"}, _runtime_owner_view, active_run_view) do
    "Starts fail closed until #{active_run_view.error || "the malformed active-run metadata"} is repaired or removed."
  end

  defp detail(%{status: "blocked", reason: "babysitter_already_running"}, _runtime_owner_view, active_run_view) do
    "Wait for the active managed #{active_run_view.mode || active_run_view.action || "run"} to finish or stop it before launching another one."
  end

  defp detail(%{status: "blocked", reason: "babysitter_unmanaged_active"}, _runtime_owner_view, active_run_view) do
    "Forgeloop sees active unmanaged run metadata#{detail_suffix(active_run_view.runtime_surface)}; clear or reconcile it before starting another run."
  end

  defp detail(%{status: "blocked", reason: "active_runtime_owned_by"}, runtime_owner_view, _active_run_view) do
    "A live #{runtime_owner_view.surface || "runtime"} #{runtime_owner_view.mode || "run"} still owns the claim#{detail_suffix(runtime_owner_view.claim_id)}. Wait for it to release or intervene manually."
  end

  defp detail(_gate, runtime_owner_view, active_run_view) do
    parts =
      [
        if(runtime_owner_view.reclaimable?, do: "the stale runtime claim will be reclaimed on the next managed start"),
        if(active_run_view.state == "stale", do: "stale active-run metadata will be cleaned before launch")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] ->
        "No live ownership conflicts or malformed run metadata are blocking a manual start."

      [single] ->
        String.capitalize(single) <> "."

      many ->
        many
        |> Enum.join(" and ")
        |> Kernel.<>(".")
        |> String.capitalize()
    end
  end

  defp details_or_nil(view) when is_map(view), do: if(Enum.any?(view, fn {_k, value} -> not is_nil(value) end), do: view, else: nil)
  defp details_or_nil(_), do: nil

  defp detail_suffix(nil), do: ""
  defp detail_suffix(""), do: ""
  defp detail_suffix(value), do: " (#{value})"

  defp truthy?(value) when value in [true, "true", 1, "1", "yes", "on"], do: true
  defp truthy?(_), do: false
end
