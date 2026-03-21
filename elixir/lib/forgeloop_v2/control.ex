defmodule ForgeloopV2.ControlFiles do
  @moduledoc false

  alias ForgeloopV2.{Config, ControlLock, Coordination}
  alias ForgeloopV2.Coordination.Question

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
      {:ok, body} -> has_marker?(body, marker)
      _ -> false
    end
  end

  @spec append_flag(Config.t(), atom() | binary()) :: :ok | {:error, term()}
  def append_flag(%Config{} = config, flag), do: append_flag(config, flag, [])

  @spec append_flag(Config.t(), atom() | binary(), keyword()) :: :ok | {:error, term()}
  def append_flag(%Config{} = config, flag, opts) do
    with :ok <- ensure(config),
         {:ok, result} <-
           ControlLock.with_lock(config, config.requests_file, :repo, lock_opts(config, opts), fn ->
             with {:ok, body} <- read_file_for_update(config.requests_file) do
               marker = marker(flag)

               if has_marker?(body, marker) do
               :ok
             else
                 ControlLock.atomic_write(config, config.requests_file, :repo, append_marker(body, marker))
               end
             end
           end) do
      result
    end
  end

  @spec append_pause_flag(Config.t()) :: :ok | {:error, term()}
  def append_pause_flag(%Config{} = config), do: append_pause_flag(config, [])

  @spec append_pause_flag(Config.t(), keyword()) :: :ok | {:error, term()}
  def append_pause_flag(%Config{} = config, opts), do: append_flag(config, "PAUSE", opts)

  @spec consume_flag(Config.t(), atom() | binary()) :: :ok | {:error, term()}
  def consume_flag(%Config{} = config, flag), do: consume_flag(config, flag, [])

  @spec consume_flag(Config.t(), atom() | binary(), keyword()) :: :ok | {:error, term()}
  def consume_flag(%Config{} = config, flag, opts) do
    with :ok <- ensure(config),
         {:ok, result} <-
           ControlLock.with_lock(config, config.requests_file, :repo, lock_opts(config, opts), fn ->
             with {:ok, body} <- read_file_for_update(config.requests_file) do
               updated = remove_marker_lines(body, marker(flag))

               if updated == body do
               :ok
             else
                 ControlLock.atomic_write(config, config.requests_file, :repo, updated)
               end
             end
           end) do
      result
    end
  end

  @spec answer_question(Config.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def answer_question(%Config{} = config, question_id, answer, opts \\ []) do
    expected_revision = Keyword.get(opts, :expected_revision)

    if is_nil(expected_revision) do
      {:error, {:missing_expected_revision, question_id}}
    else
      mutate_question(config, question_id, :answer, Keyword.put(opts, :answer, answer))
    end
  end

  @spec resolve_question(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_question(%Config{} = config, question_id, opts \\ []) do
    expected_revision = Keyword.get(opts, :expected_revision)

    if is_nil(expected_revision) do
      {:error, {:missing_expected_revision, question_id}}
    else
      mutate_question(config, question_id, :resolve, opts)
    end
  end

  @spec append_question_section(Config.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def append_question_section(%Config{} = config, rendered_section, opts \\ []) when is_binary(rendered_section) do
    with :ok <- ensure(config),
         {:ok, result} <-
           ControlLock.with_lock(config, config.questions_file, :repo, lock_opts(config, opts), fn ->
             with {:ok, body} <- read_file_for_update(config.questions_file) do
               ControlLock.atomic_write(config, config.questions_file, :repo, append_section(body, rendered_section))
             end
           end) do
      result
    end
  end

  @spec unanswered_question_ids(Config.t()) :: [String.t()]
  def unanswered_question_ids(%Config{} = config) do
    Coordination.unanswered_question_ids(config)
  end

  defp mutate_question(%Config{} = config, question_id, action, opts) do
    with :ok <- ensure(config),
         {:ok, result} <-
           ControlLock.with_lock(config, config.questions_file, :repo, lock_opts(config, opts), fn ->
             with {:ok, body} <- read_file_for_update(config.questions_file),
                  {:ok, %Question{} = question} <- normalize_question_lookup(Coordination.find_question(body, question_id), question_id),
                  {:ok, rewritten_section} <- Coordination.rewrite_question(question, action, answer: Keyword.get(opts, :answer)) do
               cond do
                 question_already_matches?(question, action, Keyword.get(opts, :answer)) ->
                   {:ok, %{question: question, changed?: false}}

                 rewritten_section == question.raw_section ->
                   {:ok, %{question: question, changed?: false}}

                 question.revision != Keyword.fetch!(opts, :expected_revision) ->
                   {:error, {:question_conflict, question_id, question.revision}}

                 true ->
                   updated_body = replace_section(body, question.section_range, rewritten_section)

                   with :ok <- ControlLock.atomic_write(config, config.questions_file, :repo, updated_body),
                        {:ok, updated_question} <- normalize_question_lookup(Coordination.find_question(updated_body, question_id), question_id) do
                     {:ok, %{question: updated_question, changed?: true}}
                   end
               end
             end
           end) do
      result
    end
  end

  defp normalize_question_lookup({:ok, question}, _question_id), do: {:ok, question}
  defp normalize_question_lookup(:missing, question_id), do: {:error, {:question_not_found, question_id}}
  defp normalize_question_lookup({:error, reason}, _question_id), do: {:error, reason}

  defp replace_section(body, {start_idx, end_idx}, rewritten_section) do
    prefix = binary_part(body, 0, start_idx)
    suffix = binary_part(body, end_idx, byte_size(body) - end_idx)
    prefix <> rewritten_section <> suffix
  end

  defp question_already_matches?(%Question{} = question, :answer, answer) do
    question.status_kind == :answered and normalize_answer(question.answer) == normalize_answer(answer)
  end

  defp question_already_matches?(%Question{} = question, :resolve, answer) do
    question.status_kind == :resolved and
      (is_nil(answer) or normalize_answer(question.answer) == normalize_answer(answer))
  end

  defp normalize_answer(nil), do: nil
  defp normalize_answer(answer), do: answer |> to_string() |> String.trim() |> blank_to_nil()

  defp touch(path) do
    File.mkdir_p!(Path.dirname(path))

    case File.exists?(path) do
      true -> :ok
      false -> File.write(path, "")
    end
  end

  defp read_file_for_update(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp has_marker?(body, marker) do
    Regex.match?(marker_regex(marker), body)
  end

  defp append_marker("", marker), do: marker <> "\n"

  defp append_marker(body, marker) do
    if String.ends_with?(body, "\n") do
      body <> marker <> "\n"
    else
      body <> "\n" <> marker <> "\n"
    end
  end

  defp remove_marker_lines(body, marker) do
    Regex.replace(marker_line_regex(marker), body, "")
  end

  defp append_section("", rendered_section), do: String.trim_leading(rendered_section, "\n")
  defp append_section(body, rendered_section), do: body <> rendered_section

  defp marker_regex(marker), do: ~r/^[ \t]*#{Regex.escape(marker)}[ \t]*\r?$/m
  defp marker_line_regex(marker), do: ~r/^[ \t]*#{Regex.escape(marker)}[ \t]*(?:\r?\n|\z)/m

  defp lock_opts(%Config{} = config, opts) do
    [timeout_ms: Keyword.get(opts, :lock_timeout_ms, Keyword.get(opts, :timeout_ms, config.control_lock_timeout_ms))]
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
    {action_label, suggested_command, follow_up_command} = action_details(requested_action)
    evidence_note = evidence_note(attrs)

    body = [
      "",
      "## Q-#{id} (#{timestamp})",
      "**Category**: blocked",
      "**Question**: Forgeloop stopped after repeated `#{kind}` failure (#{repeat_count} x): #{summary}",
      "**Status**: ⏳ Awaiting response",
      "",
      "**Suggested action**: Please #{action_label}.",
      "**Suggested command**: `#{serve_command(config)}`",
      "**Optional follow-up**: `#{suggested_command}`",
      "**Escalation log**: `#{Path.basename(config.escalations_file)}`",
      "**Evidence**: `#{evidence_note}`",
      "**Operator note**: #{follow_up_command}",
      "",
      "**Answer**:",
      "",
      "---",
      ""
    ]
    |> Enum.join("\n")

    ControlFiles.append_question_section(config, body)
  end

  defp append_escalation(config, attrs) do
    id = escalation_id(attrs)
    timestamp = human_now()
    host = hostname()
    kind = string_attr(attrs, :kind, "spin")
    summary = string_attr(attrs, :summary, "Forgeloop detected a repeated failure")
    repeat_count = string_attr(attrs, :repeat_count, "1")
    requested_action = string_attr(attrs, :requested_action, "issue")
    {action_label, suggested_command, follow_up_command} = action_details(requested_action)
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
      "Start the local operator HUD first:",
      "`#{serve_command(config)}`",
      "",
      "Suggested next move: #{action_label}.",
      "",
      "Optional follow-up command:",
      "`#{suggested_command}`",
      "",
      "Notes:",
      "- #{follow_up_command}",
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

  defp action_details("pr"),
    do:
      {"inspect the local HUD, then push a PR with the fix", "gh pr create --fill",
       "Use GitHub only after the local HUD and repo-local artifacts make the next move clear."}

  defp action_details("review"),
    do:
      {"inspect the local HUD, then review the draft and decide the next move",
       "gh pr comment <pr-number> --body-file .forgeloop/escalation-note.md",
       "Treat GitHub review as a follow-up after the local HUD / QUESTIONS.md / ESCALATIONS.md review."}

  defp action_details("rerun"),
    do:
      {"inspect the local HUD, fix the failure, and rerun the loop", "./forgeloop/bin/loop.sh 1",
       "Use the HUD to inspect evidence and clear `[PAUSE]` only when the repo-local state is ready."}

  defp action_details(_),
    do:
      {"inspect the local HUD, then file an issue or start a focused fix branch",
       "gh issue create --title \"Forgeloop spin: <summary>\" --body-file .forgeloop/escalation-note.md",
       "GitHub follow-up is optional and secondary to the local HUD + repo-local artifact chain."}

  defp serve_command(%Config{} = config) do
    if config.forgeloop_root == config.repo_root do
      "./forgeloop.sh serve"
    else
      "./forgeloop/forgeloop.sh serve"
    end
  end

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

  alias ForgeloopV2.{Config, ControlFiles, DaemonStateStore, Events}

  @spec check(Config.t()) ::
          {:clear, %{count: 0}}
          | {:tracking, %{count: pos_integer(), hash: String.t(), ids: [String.t()]}}
          | {:threshold_reached, %{count: pos_integer(), hash: String.t(), ids: [String.t()]}}
  def check(%Config{} = config) do
    ids = ControlFiles.unanswered_question_ids(config)

    case ids do
      [] ->
        {:ok, _} = DaemonStateStore.patch(config, %{"blocked_iteration_count" => 0, "last_blocker_hash" => ""})
        {:clear, %{count: 0}}

      ids ->
        hash = hash_ids(ids)

        {:ok, state} =
          DaemonStateStore.update(config, fn state ->
            count =
              if Map.get(state, "last_blocker_hash", "") == hash do
                Map.get(state, "blocked_iteration_count", 0) + 1
              else
                1
              end

            state
            |> Map.put("blocked_iteration_count", count)
            |> Map.put("last_blocker_hash", hash)
          end)

        count = Map.get(state, "blocked_iteration_count", 0)

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

  defp hash_ids(ids) do
    :crypto.hash(:sha256, Enum.join(Enum.sort(ids), "\n"))
    |> Base.encode16(case: :lower)
  end
end
