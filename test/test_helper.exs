# The engine tests need a MySQL database. Point BILDAD_TEST_DATABASE_URL at a scratch
# database; it is created if missing and the shipped migration template is run against it.
Application.put_env(:bildad, Bildad.TestRepo,
  url: System.get_env("BILDAD_TEST_DATABASE_URL", "ecto://root:root@localhost:3306/bildad_test"),
  pool_size: 10,
  log: false
)

{:ok, _} = Application.ensure_all_started(:myxql)

case Ecto.Adapters.MyXQL.storage_up(Bildad.TestRepo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _} = Bildad.TestRepo.start_link()

# The same migration `mix bildad.install` copies into a host application.
Code.require_file("priv/templates/jobs_migration.exs.eex")

Ecto.Migrator.up(Bildad.TestRepo, 20_241_115_000_000, Bildad.Repo.Migrations.AddJobsFramework,
  log: false
)

ExUnit.start(capture_log: true)
