defmodule Customer.Web.Services.JobSourceCreator do
  use Customer.Web, :service
  alias Ecto.Multi

  @company_attributes [:name, :url]
  @job_source_attributes [:title, :url, :job_title, :detail, :source]

  def perform(params) do
    case Areas.get_by!(params.place) do
      nil -> IO.inspect params.place
      area ->
        Multi.new
          |> Companies.get_or_create_by(company_attributes(params))
          |> upsert_job_source(params, area.id)
          |> bulk_upsert_job_source_tech_keywords(params.keywords)
          |> get_or_create_job_title(params.job_title)
          |> upsert_job
          |> bulk_upsert_job_tech_keywords_if_needed
          |> Repo.transaction
    end

  end

  defp upsert_job_source(multi, params, area_id) do
    Multi.merge(multi, fn %{company: company} ->
      JobSources.upsert(Multi.new, job_source_attributes(params, company.id, area_id))
    end)
  end

  defp upsert_job(multi) do
    Multi.merge(multi, fn %{job_source: job_source, job_title_id: job_title_id} ->
      Jobs.upsert(Multi.new, job_source, job_title_id)
    end)
  end

  defp get_or_create_job_title(multi, job_title) do
    case JobTitleAlias.get_or_find_approximate_job_title(job_title) do
      {:ok, job_title_id} -> Multi.run(multi, :job_title_id, fn _ -> {:ok, job_title_id} end)
      {:error, _} ->
        JobTitles.create_job_title_and_alias(multi, job_title)
        |> Multi.run(:job_title_id, fn %{job_title: job_title} -> {:ok, job_title.id} end)
    end
  end

  defp bulk_upsert_job_source_tech_keywords(multi, keyword_names) do
    Multi.merge(multi, fn %{job_source: job_source} ->
      bulk_upsert_job_source_tech_keywords(Multi.new, keyword_names, job_source.id)
    end)
  end

  defp bulk_upsert_job_source_tech_keywords(multi, keyword_names, _job_source_id) when is_nil(keyword_names), do: multi
  defp bulk_upsert_job_source_tech_keywords(multi, keyword_names, job_source_id) do
    TechKeyword.by_names(keyword_names)
    |> TechKeywords.pluck(:id)
    |> JobSourceTechKeywords.bulk_delete_and_upsert(job_source_id)
  end

  defp bulk_upsert_job_tech_keywords_if_needed(multi) do
    Multi.merge(multi, fn %{job: job} ->
      bulk_upsert_job_tech_keywords_if_needed(Multi.new, job)
    end)
  end

  defp bulk_upsert_job_tech_keywords_if_needed(multi, %Job{detail: detail}) when is_nil(detail), do: multi
  defp bulk_upsert_job_tech_keywords_if_needed(multi, %Job{id: id, detail: detail}) do
    JobSourceTechKeywords.tech_keyword_ids_by(detail["job_source_id"])
    |> JobTechKeywords.bulk_delete_and_upsert(id)
  end

  defp company_attributes(params) do
    Map.take(params, @company_attributes)
  end

  defp job_source_attributes(params, company_id, area_id) do
    params
    |> Map.take(@job_source_attributes)
    |> Enum.into(%{company_id: company_id, area_id: area_id})
  end

end
