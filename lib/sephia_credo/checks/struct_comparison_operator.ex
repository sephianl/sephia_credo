defmodule SephiaCredo.Checks.StructComparisonOperator do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      extra_modules: []
    ],
    explanations: [
      check: """
      Comparison operators use Erlang term order on structs, which walks the
      fields in declaration order rather than comparing values.

          Decimal.new("1.0") == Decimal.new("1.00")   # false
          Decimal.new("1.5") > Decimal.new("2")       # true

      Use the module's own `compare/2` (or `Decimal.eq?/2`):

          Date.compare(a, b) == :lt
          DateTime.compare(a, b) in [:gt, :eq]

      Covers `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Decimal` and
      `Version`; add your own with `extra_modules`.
      """,
      params: [
        extra_modules:
          "Further struct modules to track, as atoms or strings — `[Money, \"Cldr.Unit\"]`."
      ]
    ]

  alias Credo.Check.Params

  @ops [:<, :>, :<=, :>=, :==, :!=]

  @builtin_modules [
    [:Date],
    [:DateTime],
    [:NaiveDateTime],
    [:Time],
    [:Decimal],
    [:Version]
  ]

  @sigils [:sigil_D, :sigil_U, :sigil_N, :sigil_T]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    extra = Params.get(params, :extra_modules, __MODULE__)
    modules = @builtin_modules ++ Enum.map(extra, &normalize_module/1)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta, modules)
      {:error, _} -> []
    end
  end

  defp normalize_module(mod) when is_atom(mod) do
    mod |> Module.split() |> List.last() |> String.to_atom() |> List.wrap()
  end

  defp normalize_module(mod) when is_list(mod), do: mod

  defp normalize_module(mod) when is_binary(mod) do
    mod |> String.to_atom() |> List.wrap()
  end

  defp find_issues(ast, issue_meta, modules) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {op, meta, [left, right]} = node, acc when op in @ops ->
          flagged =
            if op in [:==, :!=] do
              strict_struct_value?(left, modules) and strict_struct_value?(right, modules)
            else
              detectable_struct?(left, modules) or detectable_struct?(right, modules)
            end

          if flagged do
            module_hint = pick_module_hint(left, right, modules)
            suggestion = suggestion_for(op, module_hint)

            issue =
              format_issue(
                issue_meta,
                message: "Avoid `#{op}` for struct comparison. Use `#{suggestion}` instead.",
                trigger: to_string(op),
                line_no: meta[:line]
              )

            {node, [issue | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp detectable_struct?(node, modules) do
    sigil?(node) or struct_literal?(node, modules) or module_call?(node, modules)
  end

  defp strict_struct_value?(node, modules) do
    sigil?(node) or struct_literal?(node, modules)
  end

  defp sigil?({sigil, _m, _args}) when sigil in @sigils, do: true
  defp sigil?(_), do: false

  defp struct_literal?({:%, _m, [{:__aliases__, _, mod}, {:%{}, _, _}]}, modules) do
    mod in modules
  end

  defp struct_literal?(_, _), do: false

  defp module_call?({{:., _m, [{:__aliases__, _, mod}, _fun]}, _call_meta, _args}, modules) do
    mod in modules
  end

  defp module_call?(_, _), do: false

  defp pick_module_hint(left, right, modules) do
    module_for(left, modules) || module_for(right, modules) || [:Date]
  end

  defp module_for({sigil, _, _}, _modules) when sigil in @sigils, do: sigil_module(sigil)

  defp module_for({:%, _, [{:__aliases__, _, mod}, _]}, modules) do
    if mod in modules, do: mod, else: nil
  end

  defp module_for({{:., _, [{:__aliases__, _, mod}, _fun]}, _, _}, modules) do
    if mod in modules, do: mod, else: nil
  end

  defp module_for(_, _), do: nil

  defp sigil_module(:sigil_D), do: [:Date]
  defp sigil_module(:sigil_T), do: [:Time]
  defp sigil_module(:sigil_U), do: [:DateTime]
  defp sigil_module(:sigil_N), do: [:NaiveDateTime]

  defp suggestion_for(op, mod) do
    name = Enum.join(mod, ".")
    "#{name}.compare(a, b) #{compare_match(op)}"
  end

  defp compare_match(:==), do: "== :eq"
  defp compare_match(:!=), do: "!= :eq"
  defp compare_match(:<), do: "== :lt"
  defp compare_match(:>), do: "== :gt"
  defp compare_match(:<=), do: "in [:lt, :eq]"
  defp compare_match(:>=), do: "in [:gt, :eq]"
end
