defmodule Mix.Tasks.Bildad.Gen.RunDetailsMigration do
  use Mix.Task

  @shortdoc "Generates the migration for Bildad's optional job_run_details table"

  @moduledoc """
  Writes the migration that creates the `job_run_details` table, for an application that
  already has Bildad's tables (from `mix bildad.install`).

      mix bildad.gen.run_details_migration
      mix bildad.gen.run_details_migration --migrations-path priv/my_repo/migrations

  The table is only used once run details are enabled (see `Bildad.Config`):

      config :bildad, run_details: true

  Run the migration before enabling them. Until it has run, enabling them makes Bildad log
  an error every minute; jobs are not affected.

  Does nothing if a migration named `*_add_bildad_job_run_details.exs` already exists.
  """

  @migration_suffix "_add_bildad_job_run_details.exs"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [migrations_path: :string])
    path = Keyword.get(opts, :migrations_path, "priv/repo/migrations")

    case Path.wildcard(Path.join(path, "*" <> @migration_suffix)) do
      [existing | _] ->
        Mix.shell().info("A job_run_details migration already exists: #{existing}")

      [] ->
        File.mkdir_p!(path)
        file = Path.join(path, timestamp() <> @migration_suffix)
        File.write!(file, File.read!(template_path()))
        Mix.shell().info("Wrote #{file}")

        Mix.shell().info("""

        Run `mix ecto.migrate`, then enable run details in your config:

            config :bildad, run_details: true
        """)
    end
  end

  defp template_path do
    Application.app_dir(:bildad, ["priv", "templates", "run_details_migration.exs.eex"])
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss]) |> to_string()
  end
end
