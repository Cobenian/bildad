defmodule Bildad.TestRepo do
  @moduledoc false
  # The repository the engine tests run against. Configured in test/test_helper.exs from
  # BILDAD_TEST_DATABASE_URL.
  use Ecto.Repo, otp_app: :bildad, adapter: Ecto.Adapters.MyXQL
end

defmodule Bildad.TestRepo.Unavailable do
  @moduledoc false
  # Stands in for the repository when the database cannot be reached: reads that a launch
  # needs go to the real repository, every transaction fails.
  defdelegate preload(structs, preloads), to: Bildad.TestRepo

  def transaction(_fun_or_multi, _opts \\ []) do
    send(:bildad_test, :transaction_attempted)
    raise DBConnection.ConnectionError, "connection not available (simulated)"
  end
end
