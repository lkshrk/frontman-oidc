alias FrontmanServer.Accounts
alias FrontmanServer.Accounts.Scope
alias FrontmanServer.Providers

provider_config =
  :frontman_server
  |> Application.fetch_env!(:providers)
  |> Keyword.fetch!(:anthropic)

[{"Claude Haiku 4.5", model, :packaged}] = provider_config.models

base_url =
  :req_llm
  |> Application.fetch_env!(:anthropic)
  |> Keyword.fetch!(:base_url)

user = Accounts.get_user_by_email("e2e@frontman.local")

{:ok, {model_spec, llm_opts}} =
  Providers.prepare_llm_args(Scope.for_user(user), "anthropic:#{model}")

{:ok, resolved_model} = ReqLLM.model(model_spec)
{:ok, plan} = ReqLLM.plan(resolved_model, :chat, stream: true)

actual = %{
  provider: Atom.to_string(resolved_model.provider),
  model: model,
  base_url: base_url,
  access_token_matches:
    Keyword.fetch!(llm_opts, :access_token) == System.fetch_env!("ANTHROPIC_AUTH_TOKEN"),
  auth_mode: Keyword.fetch!(llm_opts, :auth_mode),
  with_claude_subscription: Keyword.fetch!(llm_opts, :with_claude_subscription),
  surface: plan.surface,
  route: plan.route
}

expected = %{
  provider: "anthropic",
  model: "claude-haiku-4-5-20251001",
  base_url: System.fetch_env!("ANTHROPIC_BASE_URL"),
  access_token_matches: true,
  auth_mode: :oauth,
  with_claude_subscription: true,
  surface: :anthropic_messages,
  route: %{method: :post, path: "/v1/messages"}
}

if actual != expected do
  raise "Anthropic API E2E contract mismatch: #{inspect(actual)}"
end

IO.puts("Anthropic API E2E contract passed")
