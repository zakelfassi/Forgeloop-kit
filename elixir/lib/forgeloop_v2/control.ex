defmodule ForgeloopV2.ControlFiles do
  @moduledoc false

  alias ForgeloopV2.{Config, Coordination}

  @spec ensure(Config.t()) :: :ok | {:error, term()}
  def ensure(%Config{} = config) do
    with :ok <- File.mkdir_p(config.runtime_dir),
         :ok <- File.mkdir_p(config.v2_state_dir),
         :ok <- touch(config.requests_file),
         :ok <- touch(config.questions_file),
         :ok <- touch(config.escalations_file) do
      :ok
    end
  end

  @spec has_flag?(Config.t(), atom() | binary()) :: boolean()
  def has_flag?(%Config{} = config, flag) do
    marker = marker(flag)

    case File.read(config.requests_file) do
      {:ok, body} -> String.contains?(body, marker)
      _ -> false
    end
  end

  @spec append_flag(Config.t(), atom() | binary()) :: :ok | {:error, term()}
  def append_flag(%Config{} = config, flag) do
    with :ok <- ensure(config) do
      marker = marker(flag)

      if has_flag?(config, flag) do
        :ok
      else
        File.write(config.requests_file, "\n#{marker}\n", [:append])
      end
    end
  end

  @spec append_pause_flag(Config.t()) :: :ok | {:error, term()}
  def append_pause_flag(%Config{} = config), do: append_flag(config, "PAUSE")

  @spec consume_flag(Config.t(), atom() | binary()) :: :ok
  def consume_flag(%Config{} = config, flag) do
    marker = marker(flag)

    case File.read(config.requests_file) do
      {:ok, body} ->
        updated =
          body
          |> String.replace("\n#{marker}\n", "\n")
          |> String.replace("#{marker}\n", "")
          |> String.replace("\n#{marker}", "\n")
          |> String.replace(marker, "")

        File.write!(config.requests_file, updated)
        :ok

      _ ->
        :ok
    end
  end

  @spec unanswered_question_ids(Config.t()) :: [String.t()]
  def unanswered_question_ids(%Config{} = config) do
    Coordination.unanswered_question_ids(config)
  end

  defp touch(path) do
    File.mkdir_p!(Path.dirname(path))

    case File.exists?(path) do
      true -> :ok
      false -> File.write(path, "")
    end
  end

  defp marker(flag) when is_atom(flag), do: marker(Atom.to_string(flag))
  defp marker(flag), do: "[#{flag |> to_string() |> String.upcase()}]"
end

defmodule ForgeloopV2.Escalation do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlFiles, RuntimeLifecycle}

  @spec escalate(Config.t(), map()) :: {:ok, %{question_id: String.t(), escalation_id: String.t()}} | {:error, term()}
  def escalate(%Config{} = config, attrs) do
    with :ok <- ControlFiles.ensure(config),
         :ok <- ControlFiles.append_pause_flag(config),
         {:ok, _state} <-
           RuntimeLifecycle.transition(config, :human_escalated, :escalation, %{
             surface: string_attr(attrs, :surface, "loop"),
             mode: string_attr(attrs, :mode, "build"),
             reason: string_attr(attrs, :summary, "Forgeloop detected a repeated failure"),
             requested_action: string_attr(attrs, :requested_action, "issue"),
             branch: string_attr(attrs, :branch, config.default_branch)
           }),
         :ok <- append_question(config, attrs),
         :ok <- append_escalation(config, attrs) do
      id = escalation_id(attrs)
      {:ok, %{question_id: "Q-#{id}", escalation_id: "E-#{id}"}}
    end
  end

  defp append_question(config, attrs) do
    id = escalation_id(attrs)
    timestamp = human_now()
    kind = string_attr(attrs, :kind, "spin")
    summary = string_attr(attrs, :summary, "Forgeloop detected a repeated failure")
    repeat_count = string_attr(attrs, :repeat_count, "1")
    requested_action = string_attr(attrs, :requested_action, "issue")
    {action_label, suggested_command} = action_details(requested_action)
    evidence_note = evidence_note(attrs)

    body = [
      "",
      "## Q-#{id} (#{timestamp})",
      "**Category**: blocked",
      "**Question**: Forgeloop stopped after repeated `#{kind}` failure (#{repeat_count} x): #{summary}",
      "**Status**: ⏳ Awaiting response",
      "",
      "**Suggested action**: Please #{action_label}.",
      "**Suggested command**: `#{suggested_command}`",
      "**Escalation log**: `#{Path.basename(config.escalations_file)}`",
      "**Evidence**: `#{evidence_note}`",
      "",
      "**Answer**:",
      "",
      "---",
      ""
    ]
    |> Enum.join("\n")

    File.write(config.questions_file, body, [:append])
  end

  defp append_escalation(config, attrs) do
    id = escalation_id(attrs)
    timestamp = human_now()
    host = hostname()
    kind = string_attr(attrs, :kind, "spin")
    summary = string_attr(attrs, :summary, "Forgeloop detected a repeated failure")
    repeat_count = string_attr(attrs, :repeat_count, "1")
    requested_action = string_attr(attrs, :requested_action, "issue")
    {action_label, suggested_command} = action_details(requested_action)
    evidence_note = evidence_note(attrs)

    body = [
      "",
      "## E-#{id} (#{timestamp})",
      "- Kind: `#{kind}`",
      "- Repeat count: `#{repeat_count}`",
      "- Requested action: `#{requested_action}`",
      "- Summary: #{summary}",
      "- Evidence: `#{evidence_note}`",
      "- Host: `#{host}`",
      "",
      "### Draft",
      "Forgeloop hit the same `#{kind}` failure #{repeat_count} times and paused itself.",
      "",
      "Suggested next move: #{action_label}.",
      "",
      "Suggested command:",
      "`#{suggested_command}`",
      "",
      "Notes:",
      "- Inspect the evidence before resuming.",
      "- Remove `[PAUSE]` from `#{Path.basename(config.requests_file)}` when ready to continue.",
      "- Mark the matching question in `#{Path.basename(config.questions_file)}` as answered when the operator has decided.",
      "",
      "---",
      ""
    ]
    |> Enum.join("\n")

    File.write(config.escalations_file, body, [:append])
  end

  defp escalation_id(attrs), do: string_attr(attrs, :id, Integer.to_string(System.system_time(:second)))

  defp evidence_note(attrs) do
    case string_attr(attrs, :evidence_file) do
      "" -> "No evidence file captured."
      path -> path
    end
  end

  defp action_details("pr"), do: {"push a PR with the fix", "gh pr create --fill"}

  defp action_details("review"),
    do: {"review the draft and decide the next move", "gh pr comment <pr-number> --body-file .forgeloop/escalation-note.md"}

  defp action_details("rerun"), do: {"inspect the failure, fix it, and rerun the loop", "./forgeloop/bin/loop.sh 1"}
  defp action_details(_), do: {"file an issue or start a focused fix branch", "gh issue create --title \"Forgeloop spin: <summary>\" --body-file .forgeloop/escalation-note.md"}

  defp human_now do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, value} -> List.to_string(value)
      _ -> "unknown"
    end
  end

  defp string_attr(attrs, key, default \\ "") do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    cond do
      is_nil(value) -> default
      is_atom(value) -> Atom.to_string(value)
      is_binary(value) -> value
      true -> to_string(value)
    end
  end
end

defmodule ForgeloopV2.FailureSignature do
  @moduledoc false

  @error_pattern ~r/(error|fail|exception|fatal|elifecycle|err!|panicked|assert)/i

  @spec build(String.t(), String.t(), Path.t() | nil) :: String.t()
  def build(kind, summary, evidence_file \\ nil) do
    payload =
      ["kind=#{kind}", "summary=#{summary}"] ++ evidence_lines(evidence_file)

    :crypto.hash(:sha256, Enum.join(payload, "\n"))
    |> Base.encode16(case: :lower)
  end

  defp evidence_lines(nil), do: []
  defp evidence_lines(""), do: []

  defp evidence_lines(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split(~r/\R/, trim: true)
        |> Enum.filter(&Regex.match?(@error_pattern, &1))
        |> Enum.take(20)
        |> Enum.map(&normalize_line/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()
        |> case do
          [] -> []
          lines -> ["evidence=" <> Enum.join(lines, "\n")]
        end

      _ ->
        []
    end
  end

  defp normalize_line(line) do
    line
    |> String.replace(~r/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.+\-Z]*/, "")
    |> String.replace(~r/[0-9a-f]{7,40}/i, "")
    |> String.replace(~r/[0-9]+/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end

defmodule ForgeloopV2.FailureTracker do
  @moduledoc false

  alias ForgeloopV2.{Config, Escalation, Events, RuntimeLifecycle}

  @spec clear(Config.t()) :: :ok
  def clear(%Config{} = config) do
    File.rm(state_path(config))
    :ok
  end

  @spec record(Config.t(), String.t(), String.t(), Path.t() | nil) :: {:ok, pos_integer()} | {:error, term()}
  def record(%Config{} = config, kind, summary, evidence_file \\ nil) do
    File.mkdir_p!(config.v2_state_dir)
    signature = ForgeloopV2.FailureSignature.build(kind, summary, evidence_file)
    state = read_state(config)
    last_signature = Map.get(state, "last_failure_signature", "")
    last_count = Map.get(state, "last_failure_count", 0)
    count = if signature == last_signature, do: last_count + 1, else: 1

    payload = %{
      "last_failure_signature" => signature,
      "last_failure_kind" => kind,
      "last_failure_count" => count,
      "last_failure_updated_at" => human_now()
    }

    case File.write(state_path(config), Jason.encode!(payload, pretty: true) <> "\n") do
      :ok -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec handle(Config.t(), map()) :: {:retry, pos_integer()} | {:stop, pos_integer()} | {:error, term()}
  def handle(%Config{} = config, attrs) do
    kind = string_attr(attrs, :kind, "build")
    summary = string_attr(attrs, :summary, "Failure")
    evidence_file = string_attr(attrs, :evidence_file)
    requested_action = string_attr(attrs, :requested_action, config.failure_escalation_action)
    surface = string_attr(attrs, :surface, "loop")
    mode = string_attr(attrs, :mode, "build")
    branch = string_attr(attrs, :branch, config.default_branch)

    with {:ok, count} <- record(config, kind, summary, blank_to_nil(evidence_file)) do
      if count < config.failure_escalate_after do
        :ok =
          Events.emit(config, :failure_recorded, %{
            "kind" => kind,
            "summary" => summary,
            "repeat_count" => count,
            "surface" => surface,
            "mode" => mode,
            "branch" => branch,
            "evidence_file" => evidence_file
          })

        {:ok, _state} =
          RuntimeLifecycle.transition(config, :failure_blocked, writer_for(surface), %{
            surface: surface,
            mode: mode,
            reason: summary,
            requested_action: requested_action,
            branch: branch
          })

        {:retry, count}
      else
        case Escalation.escalate(config, %{
               kind: kind,
               summary: summary,
               evidence_file: evidence_file,
               repeat_count: count,
               requested_action: requested_action,
               surface: surface,
               mode: mode,
               branch: branch
             }) do
          {:ok, _} ->
            :ok =
              Events.emit(config, :failure_escalated, %{
                "kind" => kind,
                "summary" => summary,
                "repeat_count" => count,
                "surface" => surface,
                "mode" => mode,
                "branch" => branch,
                "evidence_file" => evidence_file
              })

            {:stop, count}

          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp read_state(config) do
    case File.read(state_path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> payload
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp state_path(config), do: Path.join(config.v2_state_dir, "failure-state.json")

  defp human_now do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  defp string_attr(attrs, key, default \\ "") do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    cond do
      is_nil(value) -> default
      is_atom(value) -> Atom.to_string(value)
      is_binary(value) -> value
      true -> to_string(value)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp writer_for("daemon"), do: :daemon
  defp writer_for(_surface), do: :loop
end

defmodule ForgeloopV2.BlockerDetector do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlFiles, Events}

  @spec check(Config.t()) ::
          {:clear, %{count: 0}}
          | {:tracking, %{count: pos_integer(), hash: String.t(), ids: [String.t()]}}
          | {:threshold_reached, %{count: pos_integer(), hash: String.t(), ids: [String.t()]}}
  def check(%Config{} = config) do
    ids = ControlFiles.unanswered_question_ids(config)

    case ids do
      [] ->
        save_state(config, %{"blocked_iteration_count" => 0, "last_blocker_hash" => ""})
        {:clear, %{count: 0}}

      ids ->
        hash = hash_ids(ids)
        state = read_state(config)

        count =
          if Map.get(state, "last_blocker_hash", "") == hash do
            Map.get(state, "blocked_iteration_count", 0) + 1
          else
            1
          end

        save_state(config, %{"blocked_iteration_count" => count, "last_blocker_hash" => hash})

        if count >= config.max_blocked_iterations do
          :ok =
            Events.emit(config, :blocker_escalated, %{
              "repeat_count" => count,
              "blocker_hash" => hash,
              "question_ids" => ids
            })

          {:threshold_reached, %{count: count, hash: hash, ids: ids}}
        else
          :ok =
            Events.emit(config, :blocker_tracking, %{
              "repeat_count" => count,
              "blocker_hash" => hash,
              "question_ids" => ids
            })

          {:tracking, %{count: count, hash: hash, ids: ids}}
        end
    end
  end

  defp read_state(config) do
    case File.read(state_path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> payload
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_state(config, payload) do
    File.mkdir_p!(config.v2_state_dir)
    File.write!(state_path(config), Jason.encode!(payload, pretty: true) <> "\n")
  end

  defp state_path(config), do: Path.join(config.v2_state_dir, "daemon-state.json")

  defp hash_ids(ids) do
    :crypto.hash(:sha256, Enum.join(Enum.sort(ids), "\n"))
    |> Base.encode16(case: :lower)
  end
end
