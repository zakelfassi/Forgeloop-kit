defmodule ForgeloopV2.Coordination.Question do
  @moduledoc false

  @type status_kind :: :awaiting_response | :answered | :resolved | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          opened_at: String.t() | nil,
          category: String.t() | nil,
          question: String.t() | nil,
          status_label: String.t() | nil,
          status_kind: status_kind(),
          suggested_action: String.t() | nil,
          suggested_command: String.t() | nil,
          escalation_log: String.t() | nil,
          evidence: String.t() | nil,
          answer: String.t() | nil,
          raw_section: String.t(),
          section_range: {non_neg_integer(), non_neg_integer()} | nil,
          revision: String.t() | nil
        }

  defstruct [
    :id,
    :opened_at,
    :category,
    :question,
    :status_label,
    :status_kind,
    :suggested_action,
    :suggested_command,
    :escalation_log,
    :evidence,
    :answer,
    :raw_section,
    :section_range,
    :revision
  ]
end

defmodule ForgeloopV2.Coordination.Escalation do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          opened_at: String.t() | nil,
          kind: String.t() | nil,
          repeat_count: integer() | nil,
          requested_action: String.t() | nil,
          summary: String.t() | nil,
          evidence: String.t() | nil,
          host: String.t() | nil,
          draft: String.t() | nil,
          raw_section: String.t()
        }

  defstruct [
    :id,
    :opened_at,
    :kind,
    :repeat_count,
    :requested_action,
    :summary,
    :evidence,
    :host,
    :draft,
    :raw_section
  ]
end

defmodule ForgeloopV2.Coordination do
  @moduledoc false

  alias ForgeloopV2.Config
  alias ForgeloopV2.Coordination.{Escalation, Question}

  @spec read_questions(Config.t()) :: {:ok, [Question.t()]} | :missing | {:error, term()}
  def read_questions(%Config{} = config) do
    case File.read(config.questions_file) do
      {:ok, body} -> {:ok, parse_questions(body)}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_questions(String.t()) :: [Question.t()]
  def parse_questions(body) when is_binary(body) do
    parse_sections(body, "Q-", &question_from_section/4)
  end

  @spec find_question(String.t(), String.t()) :: {:ok, Question.t()} | :missing | {:error, term()}
  def find_question(body, question_id) when is_binary(body) and is_binary(question_id) do
    case Enum.filter(parse_questions(body), &(&1.id == question_id)) do
      [] -> :missing
      [question] -> {:ok, question}
      _duplicates -> {:error, {:duplicate_question_id, question_id}}
    end
  end

  @spec rewrite_question(Question.t(), :answer | :resolve, keyword()) :: {:ok, String.t()} | {:error, term()}
  def rewrite_question(%Question{} = question, :answer, opts) do
    with {:ok, answer} <- required_answer(question.id, Keyword.get(opts, :answer)) do
      question.raw_section
      |> upsert_status("✅ Answered")
      |> upsert_answer(answer)
      |> then(&{:ok, &1})
    end
  end

  def rewrite_question(%Question{} = question, :resolve, opts) do
    with {:ok, maybe_answer} <- optional_answer(question.id, Keyword.get(opts, :answer)) do
      section = upsert_status(question.raw_section, "Resolved")

      section =
        case maybe_answer do
          nil -> section
          answer -> upsert_answer(section, answer)
        end

      {:ok, section}
    end
  end

  @spec unanswered_question_ids(Config.t()) :: [String.t()]
  def unanswered_question_ids(%Config{} = config) do
    case read_questions(config) do
      {:ok, questions} ->
        questions
        |> Enum.filter(&(&1.status_kind == :awaiting_response))
        |> Enum.map(& &1.id)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  @spec read_escalations(Config.t()) :: {:ok, [Escalation.t()]} | :missing | {:error, term()}
  def read_escalations(%Config{} = config) do
    case File.read(config.escalations_file) do
      {:ok, body} -> {:ok, parse_escalations(body)}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_escalations(String.t()) :: [Escalation.t()]
  def parse_escalations(body) when is_binary(body) do
    parse_sections(body, "E-", &escalation_from_section/4)
  end

  defp parse_sections(body, prefix, parser) do
    body
    |> section_ranges()
    |> Enum.reduce([], fn {start_idx, end_idx}, acc ->
      actual_end_idx = trim_trailing_section_end(body, start_idx, end_idx)
      raw_section = binary_part(body, start_idx, actual_end_idx - start_idx)
      [heading_line | rest] = String.split(raw_section, "\n", parts: 2)
      heading = heading_line |> String.trim_leading("## ") |> String.trim()
      section_body = List.first(rest) || ""

      if String.starts_with?(heading, prefix) do
        case parser.(heading, section_body, raw_section, {start_idx, actual_end_idx}) do
          nil -> acc
          parsed -> [parsed | acc]
        end
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp section_ranges(body) do
    starts =
      Regex.scan(~r/^##\s+/m, body, return: :index)
      |> Enum.map(fn [{idx, _len}] -> idx end)

    starts
    |> Enum.with_index()
    |> Enum.map(fn {start_idx, index} ->
      end_idx = Enum.at(starts, index + 1, byte_size(body))
      {start_idx, end_idx}
    end)
  end

  defp trim_trailing_section_end(body, start_idx, end_idx) do
    segment = binary_part(body, start_idx, end_idx - start_idx)
    trimmed = String.trim_trailing(segment)
    start_idx + byte_size(trimmed)
  end

  defp question_from_section(heading, body, raw_section, section_range) do
    with {id, opened_at} <- heading_info(heading, ~r/^(Q-[^\s(]+)(?:\s+\(([^)]+)\))?/) do
      status_label = labeled_value(body, "Status") || compact_status_label(body)

      %Question{
        id: id,
        opened_at: opened_at,
        category: labeled_value(body, "Category"),
        question: labeled_value(body, "Question"),
        status_label: status_label,
        status_kind: classify_status(status_label),
        suggested_action: labeled_value(body, "Suggested action"),
        suggested_command: labeled_value(body, "Suggested command"),
        escalation_log: labeled_value(body, "Escalation log"),
        evidence: labeled_value(body, "Evidence"),
        answer: labeled_value(body, "Answer"),
        raw_section: raw_section,
        section_range: section_range,
        revision: revision(raw_section)
      }
    else
      _ -> nil
    end
  end

  defp escalation_from_section(heading, body, raw_section, _section_range) do
    with {id, opened_at} <- heading_info(heading, ~r/^(E-[^\s(]+)(?:\s+\(([^)]+)\))?/) do
      %Escalation{
        id: id,
        opened_at: opened_at,
        kind: bullet_value(body, "Kind"),
        repeat_count: int_value(body, "Repeat count"),
        requested_action: bullet_value(body, "Requested action"),
        summary: bullet_value(body, "Summary"),
        evidence: bullet_value(body, "Evidence"),
        host: bullet_value(body, "Host"),
        draft: draft_value(body),
        raw_section: raw_section
      }
    else
      _ -> nil
    end
  end

  defp upsert_status(section, label) do
    status_line = "**Status**: #{label}"

    cond do
      Regex.match?(~r/^\*\*Status\*\*:\s*.*$/m, section) ->
        Regex.replace(~r/^\*\*Status\*\*:\s*.*$/m, section, status_line, global: false)

      Regex.match?(~r/^\*\*Question\*\*:\s*.*(?:\n|$)/m, section) ->
        Regex.replace(
          ~r/(^\*\*Question\*\*:\s*.*(?:\n|$))/m,
          section,
          "\\1" <> status_line <> "\n",
          global: false
        )

      true ->
        Regex.replace(~r/^(##[^\n]*(?:\n|$))/, section, "\\1" <> status_line <> "\n", global: false)
    end
  end

  defp upsert_answer(section, answer) do
    answer_block = "**Answer**:\n#{String.trim(answer)}\n"

    cond do
      Regex.match?(~r/^\*\*Answer\*\*:\s*(.*?)(?=^\*\*[^*]+\*\*:|^---\s*$|\z)/ms, section) ->
        Regex.replace(
          ~r/^\*\*Answer\*\*:\s*(.*?)(?=^\*\*[^*]+\*\*:|^---\s*$|\z)/ms,
          section,
          answer_block,
          global: false
        )

      Regex.match?(~r/^---\s*$/m, section) ->
        Regex.replace(~r/^---\s*$/m, section, answer_block <> "\n---", global: false)

      true ->
        String.trim_trailing(section) <> "\n\n" <> answer_block
    end
  end

  defp required_answer(question_id, answer) do
    answer = answer |> to_string_or_nil() |> blank_to_nil()
    if is_binary(answer), do: {:ok, answer}, else: {:error, {:blank_answer, question_id}}
  end

  defp optional_answer(question_id, answer) do
    cond do
      is_nil(answer) -> {:ok, nil}
      true -> required_answer(question_id, answer)
    end
  end

  defp revision(raw_section) do
    :crypto.hash(:sha256, raw_section)
    |> Base.encode16(case: :lower)
  end

  defp heading_info(heading, regex) do
    case Regex.run(regex, heading, capture: :all_but_first) do
      [id, opened_at] -> {id, blank_to_nil(opened_at)}
      [id] -> {id, nil}
      _ -> nil
    end
  end

  defp labeled_value(body, label) do
    regex = Regex.compile!("^\\*\\*#{Regex.escape(label)}\\*\\*:\\s*(.*?)(?=^\\*\\*[^*]+\\*\\*:|^---\\s*$|\\z)", "ms")

    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> value |> clean_value() |> blank_to_nil()
      _ -> nil
    end
  end

  defp bullet_value(body, label) do
    regex = Regex.compile!("^-\\s*#{Regex.escape(label)}:\\s*(.+)$", "m")

    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> value |> clean_value() |> blank_to_nil()
      _ -> nil
    end
  end

  defp int_value(body, label) do
    case bullet_value(body, label) do
      nil -> nil
      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp draft_value(body) do
    case Regex.run(~r/^###\s+Draft\s*\n(.*?)(?=^---\s*$|\z)/ms, body, capture: :all_but_first) do
      [value] -> value |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp compact_status_label(body) do
    body
    |> :binary.split("\n", [:global])
    |> Enum.find_value(fn line ->
      trimmed =
        line
        |> String.trim_trailing("\r")
        |> String.trim()

      if Regex.match?(~r/^[-*]\s+/, trimmed) do
        case classify_status(trimmed) do
          :awaiting_response -> "Awaiting response"
          :answered -> "Answered"
          :resolved -> "Resolved"
          _ -> nil
        end
      end
    end)
  end

  defp classify_status(nil), do: :unknown

  defp classify_status(label) do
    normalized = normalize_status_label(label)

    cond do
      String.starts_with?(normalized, "awaiting response") -> :awaiting_response
      normalized == "answered" -> :answered
      normalized == "resolved" -> :resolved
      true -> :unknown
    end
  end

  defp normalize_status_label(label) do
    label
    |> :binary.bin_to_list()
    |> Enum.map(fn
      char when char in ?A..?Z -> <<char + 32>>
      char when char in ?a..?z -> <<char>>
      ?\s -> " "
      _ -> " "
    end)
    |> Enum.join()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_value(value) do
    value
    |> String.trim()
    |> trim_code_ticks()
  end

  defp trim_code_ticks(value) do
    if String.starts_with?(value, "`") and String.ends_with?(value, "`") do
      value
      |> String.trim_leading("`")
      |> String.trim_trailing("`")
      |> String.trim()
    else
      value
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_or_nil(value), do: to_string(value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
