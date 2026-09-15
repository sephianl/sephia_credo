defmodule SephiaCredo.Checks.UtcCalendarDate do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [local_date_call: nil],
    explanations: [
      check: """
      Taking a calendar date from the UTC clock assumes the project's day starts
      at midnight UTC. For a project whose business day is a local timezone it
      does not, and the date is the *previous* day's for the first hours of every
      local day — one hour behind in winter, two in summer, for a zone like
      `Europe/Amsterdam`.

          date = Date.utc_today()

      The window is small, which is the whole problem: the code is right for 22
      hours a day and wrong for two, so it passes every review, every CI run that
      starts in working hours, and every manual test anyone thinks to do. It
      surfaces as a bug report from whoever was working at 00:30.

      Measured on one 2200-file project: 39 call sites across 18 test files, all
      of them building fixtures or URL parameters for "today", turned a green
      suite red at 00:16 — the tests asked for yesterday's bucket while the
      filters they drove resolved the date in the local zone. The same
      substitution in application code cost two user-visible defects: a
      maintenance window reported as inactive between 00:00 and 02:00, and an
      order form whose time dropdown offered yesterday's date while the field
      beside it defaulted to today's, so the pair failed a same-day validation
      and the order could not be saved.

      Reported spellings, all of which produce a `Date`:

          Date.utc_today()
          DateTime.utc_now() |> DateTime.to_date()
          NaiveDateTime.utc_now() |> NaiveDateTime.to_date()

      A bare `DateTime.utc_now/0` is **not** reported. A UTC instant is a correct
      way to hold a point in time and is what should be stored; only collapsing
      one to a calendar date commits to a day boundary. That is the line this
      check draws, and it is why the check stays quiet in the many places that
      legitimately want "now".

      Test files are checked too. Exempting them is what lets the drift back in:
      a fixture dated in UTC and a filter resolving dates locally disagree for
      the same two hours, and a suite that is green at 14:00 and red at 00:16
      reads as flakiness rather than as the bug it is.

      `local_date_call` names the project's own helper so the message says what
      to write instead. Genuinely UTC-keyed values — a UTC-partitioned object
      key, a retention cutoff defined in UTC — are the case for
      `# credo:disable-for-next-line`, since there the UTC day is the intended
      one.
      """,
      params: [
        local_date_call:
          "The project's local-date call, e.g. `\"LocalTime.today()\"`, named in the message as the replacement."
      ]
    ]

  alias Credo.Check.Params
  alias SephiaCredo.Ast

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    replacement = Params.get(params, :local_date_call, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> ast |> Ast.unpipe() |> find_issues(issue_meta, replacement)
      {:error, _reason} -> []
    end
  end

  defp find_issues(ast, issue_meta, replacement) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case trigger(node) do
          nil -> {node, acc}
          {name, line} -> {node, [issue(issue_meta, name, line, replacement) | acc]}
        end
      end)

    Enum.reverse(issues)
  end

  defp trigger({{:., _, [{:__aliases__, _, [:Date]}, :utc_today]}, meta, args})
       when is_list(args) and length(args) <= 1,
       do: {"Date.utc_today", meta[:line]}

  defp trigger({{:., _, [{:__aliases__, _, [module]}, :to_date]}, meta, [argument | _rest]})
       when module in [:DateTime, :NaiveDateTime] do
    if utc_now?(argument, module), do: {"#{module}.to_date", meta[:line]}, else: nil
  end

  defp trigger(_node), do: nil

  defp utc_now?({{:., _, [{:__aliases__, _, [module]}, :utc_now]}, _meta, args}, module)
       when is_list(args) and length(args) <= 1,
       do: true

  defp utc_now?(_argument, _module), do: false

  defp issue(issue_meta, name, line_no, replacement) do
    format_issue(
      issue_meta,
      message:
        "`#{name}` takes the calendar date from the UTC clock, which is the previous " <>
          "day's date for the first hours of every local day. " <> advice(replacement),
      trigger: name,
      line_no: line_no
    )
  end

  defp advice(nil), do: "Derive the date in the project's operating timezone instead."

  defp advice(replacement), do: "Use `#{replacement}` instead."
end
