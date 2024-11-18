defmodule Mix.Tasks.Bildad.Install do
  use Mix.Task

  @shortdoc "Install controllers, migration and prints information about updating the router and application.ex file"
  def run(args) do
    IO.puts("Installing Bildad Jobs Framework...#{inspect(args)}")
    OptionParser.parse(args, strict: [application: :string])
    |> case do
      {[application: application], _, _} ->
        do_install(application)

      _bad_args ->
        IO.puts(usage())
    end
  end

  def usage() do
    """
    You must provide the name of the application you want to install the Bildad Jobs Framework into.

    For example:

    mix bildad.install --application my_app
    """
  end

  def do_install(application) do
    controller_template_content = File.read!("./templates/jobs_controller.ex.eex")

    controller_file_content =
      EEx.eval_string(controller_template_content,
        application_name: Macro.camelize(application)
      )

    File.write!(
      "./lib/#{Macro.underscore(application)}_web/controllers/jobs_controller.ex",
      controller_file_content
    )

    migration_template_content = File.read!("./templates/jobs_migration.ex.eex")
    now = DateTime.utc_now()
    zero_padded_month = zero_pad(now.month)
    zero_padded_day = zero_pad(now.day)
    zero_padded_hour = zero_pad(now.hour)
    zero_padded_minute = zero_pad(now.minute)
    zero_padded_second = zero_pad(now.second)

    date_prefix =
      "#{now.year}#{zero_padded_month}#{zero_padded_day}#{zero_padded_hour}#{zero_padded_minute}#{zero_padded_second}"

    File.write!(
      "./priv/repo/migrations/#{date_prefix}_add_bildad_jobs_framework.exs",
      migration_template_content
    )

    IO.puts("")
    IO.puts("Add the following line to your router.ex file:")

    IO.puts("""
    #{IO.ANSI.blue()}  post "/jobs/engine/run", Jobs.JobsController, :run_job_engine#{IO.ANSI.reset()}
    """)

    IO.puts("")

    IO.puts(
      "#{IO.ANSI.green()}Be sure to ONLY put the above line inside of a scope that is protected by authentication.#{IO.ANSI.reset()}"
    )

    IO.puts("")

    IO.puts("Add the following to the list of supervised children in your application.ex file:")
    IO.puts("")

    IO.puts("""
    #{IO.ANSI.blue()}{Bildad.Job.JobKiller, check_time_in_seconds: 20},#{IO.ANSI.reset()}
    """)

    IO.puts("")
  end

  def zero_pad(nbr) do
    :io_lib.format("~2..0B", [nbr]) |> List.to_string()
  end
end
