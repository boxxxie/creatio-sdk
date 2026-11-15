defmodule Creatio.FeatureScenario do
  @moduledoc """
  Provides the `scenario/2` macro for Layer 1 ATDD executable specifications.

  Each `@given`, `@upon`, `@whenever`, and `@then` step pipes an explicit per-test
  `ctx` map from step to step while preserving the Layer 1 source line number.
  """

  @doc """
  Defines an ExUnit test structured as `@given`, `@upon`/`@whenever`, and `@then` steps.
  """
  defmacro scenario(description, do: block) do
    lines =
      case block do
        {:__block__, _, exprs} -> exprs
        single -> [single]
      end

    ctx_var = Macro.unique_var(:ctx, __MODULE__)

    init_ctx =
      quote do
        Map.put_new(unquote(ctx_var), :test_id, System.unique_integer([:positive]))
      end

    piped_steps =
      Enum.reduce(lines, init_ctx, fn
        {:@, step_meta, [{step_kind, _, [call]}]}, acc
        when step_kind in [:given, :upon, :whenever, :then] ->
          step_line = Keyword.get(step_meta, :line, __CALLER__.line)
          piped = Macro.pipe(acc, call, 0)
          Macro.update_meta(piped, &Keyword.put(&1, :line, step_line))

        other_ast, _acc ->
          err_line =
            case other_ast do
              {_, meta, _} when is_list(meta) -> Keyword.get(meta, :line, __CALLER__.line)
              _ -> __CALLER__.line
            end

          raise CompileError,
            file: __CALLER__.file,
            line: err_line,
            description:
              "Only @given, @upon, @whenever, and @then steps are allowed inside scenario/2. Got: #{Macro.to_string(other_ast)}"
      end)

    quote line: __CALLER__.line do
      test unquote(description), unquote(ctx_var) do
        _ = unquote(piped_steps)
        :ok
      end
    end
  end
end
