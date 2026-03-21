defmodule ForgeloopV2.ServiceTest do
  use ForgeloopV2.TestSupport

  @shell_sleep """
  #!/usr/bin/env bash
  set -euo pipefail
  echo "sleeping"
  sleep 30
  """

  test "repo-root service serves static UI assets and overview includes provider health" do
    repo =
      create_repo_fixture!(
        plan_content: "- [ ] pending task\n",
        questions: """
        ## Q-1
        **Question**: Need input?
        **Status**: ⏳ Awaiting response
        """,
        escalations: """
        ## E-1
        - Kind: `spin`
        - Repeat count: `2`
        - Requested action: `review`
        - Summary: Investigate repeated failure
        """
      )

    layout = create_ui_layout!(repo.repo_root, :repo_root)
    create_workflow_package!(repo.repo_root, "alpha")
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    assert {:ok, _state} =
             RuntimeStateStore.write(config, %{
               status: "running",
               transition: "building",
               surface: "daemon",
               mode: "build",
               reason: "work in progress",
               requested_action: "",
               branch: "main"
             })

    :ok = ForgeloopV2.LLM.StateStore.write(config, %{"claude_auth_failed" => true})
    :ok = Events.emit(config, :provider_attempted, %{"provider" => "claude"})
    :ok = Events.emit(config, :daemon_tick, %{"action" => "build", "reason" => "pending task"})

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    html = get_response!(base_url <> "/")
    assert html.status == 200
    assert html.headers["content-type"] =~ "text/html"
    assert html.body =~ "hud"

    css = get_response!(base_url <> "/assets/app.css")
    assert css.status == 200
    assert css.headers["content-type"] =~ "text/css"

    js = get_response!(base_url <> "/assets/app.js")
    assert js.status == 200
    assert js.headers["content-type"] =~ "application/javascript"

    payload = get_json!(base_url <> "/api/overview")
    assert payload["ok"] == true
    assert payload["data"]["runtime_state"]["status"] == "running"
    assert payload["data"]["backlog"]["needs_build?"] == true
    assert Enum.at(payload["data"]["questions"], 0)["id"] == "Q-1"
    assert Enum.at(payload["data"]["escalations"], 0)["id"] == "E-1"
    assert Enum.any?(payload["data"]["events"], &(&1["event_type"] == "daemon_tick"))
    assert Enum.at(payload["data"]["workflows"]["workflows"], 0)["entry"]["name"] == "alpha"
    assert payload["data"]["babysitter"]["running?"] == false
    assert Enum.any?(payload["data"]["provider_health"]["providers"], &(&1["name"] == "claude" and &1["status"] == "auth_failed"))

    providers = get_json!(base_url <> "/api/providers")
    assert providers["ok"] == true
    assert Enum.any?(providers["data"]["providers"], &(&1["name"] == "claude"))
  end

  test "vendored service startup resolves static assets from forgeloop/elixir" do
    repo = create_repo_fixture!()
    layout = create_ui_layout!(repo.repo_root, :vendored)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    html = get_response!(base_url <> "/")
    assert html.status == 200
    assert html.body =~ "hud"
  end

  test "pause, replan, and question answer endpoints mutate canonical files safely" do
    repo =
      create_repo_fixture!(
        questions: """
        ## Q-1
        **Question**: Need input?
        **Status**: ⏳ Awaiting response
        """
      )

    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    question = get_json!(base_url <> "/api/questions")["data"] |> Enum.at(0)
    assert post_json!(base_url <> "/api/control/pause", %{})["ok"] == true
    assert post_json!(base_url <> "/api/control/replan", %{})["ok"] == true

    answer_payload =
      post_json!(base_url <> "/api/questions/Q-1/answer", %{
        "answer" => "Proceed.",
        "expected_revision" => question["revision"]
      })

    assert answer_payload["ok"] == true
    assert answer_payload["data"]["question"]["status_kind"] == "answered"
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert File.read!(config.requests_file) =~ "[REPLAN]"
    assert File.read!(config.questions_file) =~ "Proceed."

    assert {:ok, state} = RuntimeStateStore.read(config)
    assert state.status == "paused"
    assert state.surface == "service"
  end

  test "babysitter endpoints serialize manual runs and allow stop through the loopback service" do
    repo = create_git_repo_fixture!(loop_script_body: @shell_sleep, plan_content: "- [ ] build\n")
    layout = create_ui_layout!(repo.repo_root)
    run_git!(repo.repo_root, ["add", "."])
    run_git!(repo.repo_root, ["commit", "-m", "ui layout"])

    config =
      config_for!(repo.repo_root,
        app_root: layout.app_root,
        service_port: 0,
        shell_driver_enabled: true,
        babysitter_shutdown_grace_ms: 50
      )

    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    start_payload = post_json!(base_url <> "/api/babysitter/start", %{"mode" => "build"})
    assert start_payload["ok"] == true
    assert start_payload["data"]["mode"] == "build"

    conflict = post_json_response!(base_url <> "/api/babysitter/start", %{"mode" => "build"})
    assert conflict.status == 409
    assert conflict.body["error"]["reason"] == "babysitter_already_running"

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] end)

    stop_payload = post_json!(base_url <> "/api/babysitter/stop", %{"reason" => "kill"})
    assert stop_payload["ok"] == true

    wait_until(fn -> get_json!(base_url <> "/api/babysitter")["data"]["running?"] == false end)
    assert File.read!(config.requests_file) =~ "[PAUSE]"
    assert RuntimeStateStore.status(config) == "paused"
  end

  test "stream endpoint emits bootstrap and follow-up snapshots when overview changes" do
    repo = create_repo_fixture!(plan_content: "- [ ] pending task\n")
    layout = create_ui_layout!(repo.repo_root)
    config = config_for!(repo.repo_root, app_root: layout.app_root, service_port: 0)
    {:ok, pid, base_url} = start_service!(config)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    {:ok, socket} = open_stream_socket(base_url <> "/api/stream?limit=5")
    on_exit(fn -> :gen_tcp.close(socket) end)

    first = recv_until(socket, "event: snapshot", 4_000)
    assert first =~ "event: snapshot"
    assert first =~ "pending task"

    :ok = Events.emit(config, :operator_action, %{"action" => "stream_probe"})

    second = recv_until(socket, "stream_probe", 4_000)
    assert second =~ "stream_probe"
  end

  defp start_service!(config) do
    {:ok, pid} = Service.start_link(config: config, port: config.service_port, host: config.service_host, name: nil, control_plane_name: nil)
    %{base_url: base_url} = Service.snapshot(pid)
    {:ok, pid, base_url}
  end

  defp get_json!(url) do
    response = get_response!(url)
    assert response.status == 200
    assert is_map(response.body)
    response.body
  end

  defp get_response!(url) do
    response = request!(:get, url, nil)
    assert response.status == 200
    response
  end

  defp post_json!(url, payload) do
    response = post_json_response!(url, payload)
    assert response.status == 200
    response.body
  end

  defp post_json_response!(url, payload) do
    request!(:post, url, Jason.encode!(payload))
  end

  defp request!(:get, url, _body) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        [
          "GET ", uri.path || "/", query_suffix(uri.query), " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "connection: close\r\n\r\n"
        ]
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    decode_response(response)
  end

  defp request!(:post, url, body) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        [
          "POST ", uri.path || "/", query_suffix(uri.query), " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "content-type: application/json\r\n",
          "content-length: ", Integer.to_string(byte_size(body)), "\r\n",
          "connection: close\r\n\r\n",
          body
        ]
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    decode_response(response)
  end

  defp open_stream_socket(url) do
    uri = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        [
          "GET ", uri.path || "/", query_suffix(uri.query), " HTTP/1.1\r\n",
          "host: 127.0.0.1\r\n",
          "accept: text/event-stream\r\n",
          "connection: keep-alive\r\n\r\n"
        ]
      )

    {:ok, socket}
  end

  defp recv_until(socket, needle, timeout_ms, acc \\ "") do
    if String.contains?(acc, needle) do
      acc
    else
      case :gen_tcp.recv(socket, 0, timeout_ms) do
        {:ok, chunk} -> recv_until(socket, needle, timeout_ms, acc <> chunk)
        {:error, reason} -> raise "stream closed before #{inspect(needle)}: #{inspect(reason)}\n#{acc}"
      end
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp decode_response(response) do
    [status_line, rest] = String.split(response, "\r\n", parts: 2)
    [_, status, _reason] = String.split(status_line, " ", parts: 3)
    [headers_blob, body] = String.split(rest, "\r\n\r\n", parts: 2)
    headers = parse_headers(headers_blob)

    %{
      status: String.to_integer(status),
      headers: headers,
      body: decode_body(headers, body)
    }
  end

  defp parse_headers(headers_blob) do
    headers_blob
    |> String.split("\r\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp decode_body(headers, body) do
    if String.contains?(Map.get(headers, "content-type", ""), "application/json") do
      Jason.decode!(body)
    else
      body
    end
  end

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query
end
