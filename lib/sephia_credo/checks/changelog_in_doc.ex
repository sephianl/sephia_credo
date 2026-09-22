defmodule SephiaCredo.Checks.ChangelogInDoc do
  @past_habitual ~r/(?<!\bis )(?<!\bare )(?<!\bwas )(?<!\bwere )(?<!\bbe )(?<!\bbeen )(?<!\bbeing )(?<!\bnever )(?<!\bnot )(?<!, )(?<!\. )(?<!^)used to\b/im

  @default_indicators [
    @past_habitual,
    "formerly",
    "historically",
    "instead of the old",
    "before this change",
    "prior to this change",
    "this was added because",
    "has since been",
    "no longer exists",
    "we changed",
    "we renamed",
    "we moved"
  ]

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    param_defaults: [indicators: @default_indicators],
    explanations: [
      check: """
      Docs describe what is, not what was. A reader meeting the module for the
      first time has no use for the shape it replaced, and the note outlives
      everyone who remembers the change.

          # bad
          @moduledoc \"""
          Options for the demo order form, where the form used to carry two
          mutually exclusive booleans that disabled each other.
          \"""

          # bad
          @moduledoc "Serialises a plan. It also used to default a missing unit to `:centimeter`."

          # good
          @moduledoc "Options for the demo order form: one mode, chosen from `modes/0`."

      The history is worth writing down — in the pull request, where it is dated,
      attributed and reviewable, and where it stops being something every future
      reader has to skip.

      `used to` is matched as past habitual only. The passive participle is the
      far more common reading in real docs and means nothing of the sort:

          # not reported — describes what is
          @moduledoc "Boundaries used to classify severity levels."
          @moduledoc "These credentials are never used to log in."

      A copula, `never`, or a sentence boundary before the phrase marks the
      passive reading. A bare subject does not, so `the form used to carry` is
      reported and `a key used to index` is too — the two are grammatically
      identical and no pattern separates them.

      Terms that double as domain vocabulary are deliberately absent from the
      defaults. `leftover` reads as history in `the name is a leftover` and as a
      record type in `returned in :leftover as %Leftover{} values`; a checker
      cannot tell, so it stays opt-in.

      Narrative with no marker phrase — an incident retold in the past tense, an
      alternative weighed in the present — reads as ordinary prose and needs a
      human.
      """,
      params: [
        indicators:
          "Lowercased phrases, or regexes, that mark a doc as narrating the code's own history. " <>
            "Additions like `previously`, `originally` and `leftover` catch more and " <>
            "misfire on domain prose that legitimately describes a sequence or names a record."
      ]
    ]

  alias Credo.Check.Params

  @doc_attributes [:moduledoc, :doc, :typedoc, :shortdoc]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    indicators = Params.get(params, :indicators, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta, indicators)
      {:error, _reason} -> []
    end
  end

  defp find_issues(ast, issue_meta, indicators) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case narrated_history(node, indicators) do
          nil -> {node, acc}
          found -> {node, [issue(issue_meta, found) | acc]}
        end
      end)

    Enum.reverse(issues)
  end

  defp narrated_history({:@, meta, [{attribute, _meta, [text]}]}, indicators)
       when attribute in @doc_attributes and is_binary(text) do
    case Enum.find_value(indicators, &matched_phrase(&1, text)) do
      nil -> nil
      phrase -> {attribute, phrase, meta[:line]}
    end
  end

  defp narrated_history(_node, _indicators), do: nil

  defp matched_phrase(%Regex{} = indicator, text) do
    case Regex.run(indicator, text) do
      [phrase | _captures] -> String.downcase(phrase)
      nil -> nil
    end
  end

  defp matched_phrase(indicator, text) when is_binary(indicator) do
    if String.contains?(String.downcase(text), indicator), do: indicator
  end

  defp issue(issue_meta, {attribute, phrase, line_no}) do
    format_issue(
      issue_meta,
      message:
        "`@#{attribute}` narrates the code's own history (\"#{phrase}\"). What the code did before, " <>
          "which alternative was rejected and which incident prompted the fix belong in the pull " <>
          "request; the doc describes what the module is now.",
      trigger: phrase,
      line_no: line_no
    )
  end
end
