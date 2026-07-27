# Frontman Server
# Copyright (C) 2025 Frontman AI
#
# Licensed under the AGPL-3.0 — see LICENSE for details.
# Additional terms apply — see AI-SUPPLEMENTARY-TERMS.md

defmodule FrontmanServer.Organizations.Membership do
  @moduledoc """
  Schema for organization memberships - the join between users and organizations with role.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias FrontmanServer.Accounts.User
  alias FrontmanServer.Organizations.Organization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    field :role, Ecto.Enum, values: [:owner, :member]
    field :provisioner, Ecto.Enum, values: [:manual, :oidc], default: :manual

    belongs_to :user, User
    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  # Queries

  def for_organization(query \\ __MODULE__, organization_id) do
    from m in query, where: m.organization_id == ^organization_id
  end

  def for_user(query \\ __MODULE__, user_id) do
    from m in query, where: m.user_id == ^user_id
  end

  def with_role(query \\ __MODULE__, role) do
    from m in query, where: m.role == ^role
  end

  @spec stale_oidc_memberships_for_user(binary(), [binary()]) :: Ecto.Query.t()
  def stale_oidc_memberships_for_user(user_id, organization_ids) do
    query =
      from m in __MODULE__,
        where: m.user_id == ^user_id,
        where: m.provisioner == :oidc,
        where: m.role == :member

    case organization_ids do
      [] -> query
      _ -> from m in query, where: m.organization_id not in ^organization_ids
    end
  end

  def with_user(query \\ __MODULE__) do
    from m in query, preload: [:user]
  end

  def with_organization(query \\ __MODULE__) do
    from m in query, preload: [:organization]
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :provisioner, :user_id, :organization_id])
    |> validate_required([:role, :provisioner, :user_id, :organization_id])
    |> unique_constraint([:user_id, :organization_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:organization_id)
  end
end
