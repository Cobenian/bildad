defmodule Bildad.TestRepo do
  @moduledoc false
  # The repository the engine tests run against. Configured in test/test_helper.exs from
  # BILDAD_TEST_DATABASE_URL.
  use Ecto.Repo, otp_app: :bildad, adapter: Ecto.Adapters.MyXQL
end
