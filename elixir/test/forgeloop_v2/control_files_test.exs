defmodule ForgeloopV2.ControlFilesTest do
  use ForgeloopV2.TestSupport

  test "answering a question updates only the targeted section" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: First?
        **Status**: ⏳ Awaiting response

        **Answer**:

        ---

        ## Q-2
        **Question**: Second?
        **Status**: ⏳ Awaiting response

        **Answer**:

        ---
        """
      )

    config = config_for!(repo.repo_root)
    body_before = File.read!(config.questions_file)
    assert {:ok, q1_before} = Coordination.find_question(body_before, "Q-1")
    assert {:ok, q2_before} = Coordination.find_question(body_before, "Q-2")

    assert {:ok, %{question: q1_after, changed?: true}} =
             ControlFiles.answer_question(config, "Q-1", "Yes.", expected_revision: q1_before.revision)

    body_after = File.read!(config.questions_file)
    assert {:ok, q2_after} = Coordination.find_question(body_after, "Q-2")
    assert q2_after.raw_section == q2_before.raw_section
    assert q1_after.status_kind == :answered
    assert q1_after.answer == "Yes."
  end

  test "resolving a question updates only the target and clears unanswered status on next read" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: Need a call
        **Status**: ⏳ Awaiting response

        ---

        ## Q-2
        **Question**: Keep waiting
        **Status**: ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    body = File.read!(config.questions_file)
    assert {:ok, q1} = Coordination.find_question(body, "Q-1")

    assert {:ok, %{question: resolved, changed?: true}} =
             ControlFiles.resolve_question(config, "Q-1", expected_revision: q1.revision)

    assert resolved.status_kind == :resolved
    assert Coordination.unanswered_question_ids(config) == ["Q-2"]
  end

  test "re-answering with the same answer is idempotent even with a stale revision" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: First?
        **Status**: ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    body = File.read!(config.questions_file)
    assert {:ok, q1} = Coordination.find_question(body, "Q-1")

    assert {:ok, %{changed?: true}} =
             ControlFiles.answer_question(config, "Q-1", "Same answer", expected_revision: q1.revision)

    after_first = File.read!(config.questions_file)

    assert {:ok, %{changed?: false}} =
             ControlFiles.answer_question(config, "Q-1", "Same answer", expected_revision: q1.revision)

    assert File.read!(config.questions_file) == after_first
  end

  test "conflicting answer with stale revision returns conflict and leaves file unchanged" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: First?
        **Status**: ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    body = File.read!(config.questions_file)
    assert {:ok, q1} = Coordination.find_question(body, "Q-1")

    assert {:ok, %{changed?: true}} =
             ControlFiles.answer_question(config, "Q-1", "Original", expected_revision: q1.revision)

    after_first = File.read!(config.questions_file)

    assert {:error, {:question_conflict, "Q-1", _current_revision}} =
             ControlFiles.answer_question(config, "Q-1", "Different", expected_revision: q1.revision)

    assert File.read!(config.questions_file) == after_first
  end

  test "pause and replan flags add and clear idempotently" do
    repo = create_repo_fixture!(requests: "notes\n")
    config = config_for!(repo.repo_root)

    assert :ok = ControlFiles.append_flag(config, "PAUSE")
    assert :ok = ControlFiles.append_flag(config, "PAUSE")
    assert :ok = ControlFiles.append_flag(config, "REPLAN")
    assert :ok = ControlFiles.append_flag(config, :replan)
    assert ControlFiles.has_flag?(config, "PAUSE")
    assert ControlFiles.has_flag?(config, "REPLAN")

    body = File.read!(config.requests_file)
    assert length(Regex.scan(~r/^\[PAUSE\]$/m, body)) == 1
    assert length(Regex.scan(~r/^\[REPLAN\]$/m, body)) == 1

    File.write!(config.requests_file, body <> "[PAUSE]\n")
    assert :ok = ControlFiles.consume_flag(config, "PAUSE")
    assert :ok = ControlFiles.consume_flag(config, "PAUSE")
    assert :ok = ControlFiles.consume_flag(config, "REPLAN")
    refute ControlFiles.has_flag?(config, "PAUSE")
    refute ControlFiles.has_flag?(config, "REPLAN")
  end

  test "lock timeout leaves source unchanged" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: First?
        **Status**: ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    body = File.read!(config.questions_file)
    assert {:ok, q1} = Coordination.find_question(body, "Q-1")
    parent = self()

    task =
      Task.async(fn ->
        ControlLock.with_lock(config, config.questions_file, :repo, [timeout_ms: :infinity], fn ->
          send(parent, :locked)
          Process.sleep(250)
          :ok
        end)
      end)

    assert_receive :locked
    before_attempt = File.read!(config.questions_file)

    assert {:error, {:lock_timeout, _target, _lock_dir}} =
             ControlFiles.answer_question(config, "Q-1", "Blocked", expected_revision: q1.revision, lock_timeout_ms: 25)

    assert File.read!(config.questions_file) == before_attempt
    assert {:ok, :ok} = Task.await(task)
  end

  test "concurrent question answer and appended escalation question do not clobber each other" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: First?
        **Status**: ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    body = File.read!(config.questions_file)
    assert {:ok, q1} = Coordination.find_question(body, "Q-1")
    parent = self()

    holder =
      Task.async(fn ->
        ControlLock.with_lock(config, config.questions_file, :repo, [timeout_ms: :infinity], fn ->
          send(parent, :questions_locked)
          Process.sleep(150)
          :ok
        end)
      end)

    assert_receive :questions_locked

    append_task =
      Task.async(fn ->
        ControlFiles.append_question_section(
          config,
          "\n## Q-2\n**Question**: Appended while UI edit waits\n**Status**: ⏳ Awaiting response\n"
        )
      end)

    Process.sleep(10)

    answer_task =
      Task.async(fn ->
        ControlFiles.answer_question(config, "Q-1", "Answered safely", expected_revision: q1.revision)
      end)

    assert {:ok, :ok} = Task.await(holder)
    assert :ok = Task.await(append_task)
    assert {:ok, %{changed?: true}} = Task.await(answer_task)

    final_body = File.read!(config.questions_file)
    assert final_body =~ "## Q-2"
    assert final_body =~ "Appended while UI edit waits"
    assert final_body =~ "Answered safely"
  end

  test "question and pause mutations do not fake recovery state" do
    repo =
      create_repo_fixture!(
        requests: "[PAUSE]\n",
        questions: """
        ## Q-1
        **Question**: First?
        **Status**: ⏳ Awaiting response
        """
      )

    config = config_for!(repo.repo_root)
    body = File.read!(config.questions_file)
    assert {:ok, q1} = Coordination.find_question(body, "Q-1")

    assert {:ok, original_state} =
             RuntimeStateStore.write(config, %{
               status: "awaiting-human",
               transition: "escalated",
               surface: "loop",
               mode: "build",
               reason: "Waiting on Q-1",
               requested_action: "issue",
               branch: "main"
             })

    assert {:ok, %{changed?: true}} =
             ControlFiles.answer_question(config, "Q-1", "Done.", expected_revision: q1.revision)

    assert :ok = ControlFiles.consume_flag(config, "PAUSE")
    assert {:ok, current_state} = RuntimeStateStore.read(config)
    assert current_state.status == original_state.status
    assert current_state.transition == original_state.transition
    refute ControlFiles.has_flag?(config, "PAUSE")
  end
end
