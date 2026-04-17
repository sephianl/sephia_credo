defmodule SephiaCredo.Checks.NoDateTimeOperatorCompare do
  @moduledoc """
  Forbid using `<`, `>`, `<=`, `>=`, `==`, `!=` to compare date/time values.

  Prefer:
    * Date.compare(a, b) in [:lt, :eq, :gt]
    * DateTime.compare(a, b)
    * NaiveDateTime.compare(a, b)
    * Time.compare(a, b)
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      extra_modules: []
    ]

  @ops [:<, :>, :<=, :>=, :==, :!=]

  @dt_modules [
    [:Date],
    [:DateTime],
    [:NaiveDateTime],
    [:Time]
  ]

  @sigils [:sigil_D, :sigil_U, :sigil_N, :sigil_T]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    extra = params[:extra_modules] || []

    modules =
      @dt_modules ++
        Enum.map(extra, fn
          mod when is_atom(mod) ->
            mod |> Module.split() |> List.last() |> String.to_atom() |> List.wrap()

          mod when is_list(mod) ->
            mod

          mod when is_binary(mod) ->
            mod |> String.to_atom() |> List.wrap()
        end)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        find_issues(ast, issue_meta, modules)

      {:error, _parser_issues} ->
        []
    end
  end

  defp find_issues(ast, issue_meta, modules) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {op, meta, [left, right]} = node, acc when op in @ops ->
          flagged =
            if op in [:==, :!=] do
              datetime_value?(left, modules) and datetime_value?(right, modules)
            else
              datetimey?(left, modules) or datetimey?(right, modules)
            end

          if flagged do
            suggestion = suggestion_for(op)

            issue =
              format_issue(
                issue_meta,
                message:
                  "Avoid `#{op}` for date/time comparison. Use `*.compare(a, b)` (e.g. #{suggestion}).",
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

  defp datetime_value?(node, modules) do
    datetime_sigil?(node) or datetime_struct_literal?(node, modules)
  end

  defp datetimey?(node, modules) do
    datetime_value?(node, modules) or date_module_call?(node, modules)
  end

  defp datetime_sigil?({sigil, _m, _args}) when sigil in @sigils, do: true
  defp datetime_sigil?(_), do: false

  defp datetime_struct_literal?({:%, _m, [{:__aliases__, _, mod}, {:%{}, _, _}]}, modules) do
    mod in modules
  end

  defp datetime_struct_literal?(_, _modules), do: false

  defp date_module_call?({{:., _m, [{:__aliases__, _, mod}, _fun]}, _call_meta, _args}, modules) do
    mod in modules
  end

  defp date_module_call?(_other, _modules), do: false

  defp suggestion_for(:==), do: "Date.compare(a, b) == :eq"
  defp suggestion_for(:!=), do: "Date.compare(a, b) != :eq"
  defp suggestion_for(:<), do: "Date.compare(a, b) == :lt"
  defp suggestion_for(:>), do: "Date.compare(a, b) == :gt"
  defp suggestion_for(:<=), do: "Date.compare(a, b) in [:lt, :eq]"
  defp suggestion_for(:>=), do: "Date.compare(a, b) in [:gt, :eq]"
end
