defmodule SephiaCredo.Checks.DisproportionateModuleDoc do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    param_defaults: [min_doc_lines: 10, max_ratio: 0.15],
    explanations: [
      check: """
      A moduledoc that outweighs its module is documenting something the code
      should have carried itself.

      Absolute length is the wrong measure: a 700-line LiveView with a six-line
      moduledoc is fine, and the same six lines over a 20-line helper are the
      whole file. The ratio is what finds the small modules that attract the
      most prose, and small modules are where the problem concentrates —
      a one-function module is exactly where it is easiest to park a design
      note nobody has anywhere else to put.

          defmodule Oban.SnoozePolicy do
            @moduledoc \"""
            Shared ceiling for Oban jobs that answer transient failures with
            `{:snooze, _}`.

            Oban increments `job.max_attempts` on every `{:snooze, _}`, so
            `attempt < max_attempts` stays true forever and a job that keeps
            snoozing retries without bound.

            Callers that hand the result straight back to Oban must convert
            exhaustion into `{:cancel, _}` rather than re-raising: the earlier
            snoozes already inflated `max_attempts`, so a re-raised exception
            still satisfies Oban's own check and triggers extra retries.
            \"""

            @max_attempts 5

            def should_snooze?(%Oban.Job{attempt: attempt}), do: attempt < @max_attempts
          end

      Fourteen lines of doc over one line of code. The second paragraph is a
      contract every caller must honour and nothing enforces — which is the
      tell. A rule that matters enough to write down belongs in a function that
      applies it, here one returning `{:cancel, reason}` rather than a boolean
      and a paragraph explaining what to do with it.

      The other two shapes this finds:

        * prose restating data that lives elsewhere — a trusted-proxy set
          spelled out in a doc while the code reads it from config, so the two
          drift with nothing to catch it
        * a design note about a *different* system, parked in whichever module
          felt topical — solver semantics, wire formats, a dependency's
          behaviour — where it documents nothing the file contains

      Docs that are genuinely load-bearing for this code — a unit convention, an
      ordering constraint, a footgun with no other home — are the case for
      `# credo:disable-for-next-line`.

      `min_doc_lines` exists because the ratio alone misfires on very small
      modules. A 16-line module carrying one sentence of purpose and one of
      negative knowledge is at 50% and is exactly right; the default floor is
      set just above that shape, so a doc trimmed to its job is never reported
      however small its module.

      Expect a substantial first reading on an existing codebase: measured on one
      1420-module project, 173 modules at the defaults and 32 at
      `min_doc_lines: 12` / `max_ratio: 0.35`. In `credo diff` that backlog costs
      nothing — it is absorbed as the baseline — so the defaults are set where
      they catch new prose rather than where they keep the first run quiet.

      The message carries no line counts on purpose. A message embedding the
      module's live size re-reports every issue in a file the moment anyone edits
      it, which is what makes a size-based check useless in diff mode.
      """,
      params: [
        min_doc_lines:
          "Moduledocs shorter than this are never reported, however small the module. " <>
            "Keeps the check off four-line docs on ten-line modules.",
        max_ratio: "Reported once the moduledoc exceeds this fraction of the module's lines."
      ]
    ]

  alias Credo.Check.Params

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    min_doc_lines = Params.get(params, :min_doc_lines, __MODULE__)
    max_ratio = Params.get(params, :max_ratio, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta, min_doc_lines, max_ratio)
      {:error, _reason} -> []
    end
  end

  defp find_issues(ast, issue_meta, min_doc_lines, max_ratio) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case reported_line(node, min_doc_lines, max_ratio) do
          nil -> {node, acc}
          line_no -> {node, [issue(issue_meta, line_no) | acc]}
        end
      end)

    Enum.reverse(issues)
  end

  defp reported_line({:defmodule, meta, [_alias, body]} = node, min_doc_lines, max_ratio) do
    case moduledoc(body) do
      nil ->
        nil

      {line_no, doc_lines} ->
        flagged(line_no, doc_lines, span(node, meta), min_doc_lines, max_ratio)
    end
  end

  defp reported_line(_node, _min_doc_lines, _max_ratio), do: nil

  defp flagged(line_no, doc_lines, span, min_doc_lines, max_ratio)
       when doc_lines >= min_doc_lines and span > 0 and doc_lines / span > max_ratio,
       do: line_no

  defp flagged(_line_no, _doc_lines, _span, _min_doc_lines, _max_ratio), do: nil

  defp moduledoc(do: {:__block__, _meta, children}), do: Enum.find_value(children, &doc_size/1)
  defp moduledoc(do: child), do: doc_size(child)
  defp moduledoc(_body), do: nil

  defp doc_size({:@, meta, [{:moduledoc, _meta, [text]}]}) when is_binary(text),
    do: {meta[:line], line_count(text)}

  defp doc_size(_node), do: nil

  defp line_count(text) do
    text
    |> String.split("\n")
    |> Enum.drop(-1)
    |> length()
    |> occupied_lines()
  end

  defp occupied_lines(0), do: 1
  defp occupied_lines(content_lines), do: content_lines + 2

  defp span(node, meta) do
    {_node, last_line} =
      Macro.prewalk(node, meta[:line], fn
        {_form, node_meta, _args} = inner, acc when is_list(node_meta) ->
          {inner, max(acc, node_meta[:line] || acc)}

        inner, acc ->
          {inner, acc}
      end)

    last_line - meta[:line] + 2
  end

  defp issue(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "This `@moduledoc` is long relative to the module it documents, which usually means the " <>
          "prose is carrying a rule, a contract or a data set the code should carry. State what " <>
          "the module is and what the code cannot say; the rest belongs in a function or in the " <>
          "pull request.",
      trigger: "@moduledoc",
      line_no: line_no
    )
  end
end
