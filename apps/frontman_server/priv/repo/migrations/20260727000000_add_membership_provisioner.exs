defmodule FrontmanServer.Repo.Migrations.AddMembershipProvisioner do
  use Ecto.Migration

  def change do
    execute "CREATE TYPE membership_provisioner AS ENUM ('manual', 'oidc')",
            "DROP TYPE membership_provisioner"

    alter table(:memberships) do
      add :provisioner, :membership_provisioner, null: false, default: "manual"
    end
  end
end
