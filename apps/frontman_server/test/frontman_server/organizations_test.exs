defmodule FrontmanServer.OrganizationsTest do
  use FrontmanServer.DataCase

  alias Ecto.Adapters.SQL.Sandbox
  alias FrontmanServer.Accounts.User
  alias FrontmanServer.Organizations
  alias FrontmanServer.Organizations.Membership

  import FrontmanServer.Test.Fixtures.Accounts

  describe "create_organization/2" do
    test "creates organization and membership with creator as owner" do
      scope = user_scope_fixture()

      assert {:ok, organization} =
               Organizations.create_organization(scope, %{name: "My Org"})

      assert organization.name == "My Org"
      assert organization.slug == "my-org"

      # Creator should be owner - need org in scope to check
      org_scope = user_scope_fixture(scope.user, organization)
      assert Organizations.owner?(org_scope)
      assert Organizations.member?(org_scope)
    end

    test "auto-generates slug from name" do
      scope = user_scope_fixture()

      {:ok, organization} =
        Organizations.create_organization(scope, %{name: "Some Cool Org!"})

      assert organization.slug == "some-cool-org"
    end

    test "allows custom slug" do
      scope = user_scope_fixture()

      {:ok, organization} =
        Organizations.create_organization(scope, %{name: "My Org", slug: "custom-slug"})

      assert organization.slug == "custom-slug"
    end

    test "requires name" do
      scope = user_scope_fixture()

      assert {:error, changeset} =
               Organizations.create_organization(scope, %{})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "enforces unique slug" do
      scope = user_scope_fixture()

      {:ok, _org1} =
        Organizations.create_organization(scope, %{name: "First", slug: "unique-slug"})

      assert {:error, changeset} =
               Organizations.create_organization(scope, %{name: "Second", slug: "unique-slug"})

      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "list_organizations/1" do
    test "returns only organizations user is a member of" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      {:ok, org1} = Organizations.create_organization(scope1, %{name: "Org 1"})
      {:ok, _org2} = Organizations.create_organization(scope2, %{name: "Org 2"})

      orgs = Organizations.list_organizations(scope1)
      assert length(orgs) == 1
      assert hd(orgs).id == org1.id
    end

    test "returns organizations ordered by name" do
      scope = user_scope_fixture()

      {:ok, _} = Organizations.create_organization(scope, %{name: "Zebra"})
      {:ok, _} = Organizations.create_organization(scope, %{name: "Alpha"})
      {:ok, _} = Organizations.create_organization(scope, %{name: "Beta"})

      orgs = Organizations.list_organizations(scope)
      names = Enum.map(orgs, & &1.name)
      assert names == ["Alpha", "Beta", "Zebra"]
    end
  end

  describe "get_organization!/2" do
    test "returns organization if user is a member" do
      scope = user_scope_fixture()
      {:ok, org} = Organizations.create_organization(scope, %{name: "My Org"})

      assert Organizations.get_organization!(scope, org.id) == org
    end

    test "raises if user is not a member" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      {:ok, org} = Organizations.create_organization(scope1, %{name: "My Org"})

      assert_raise Ecto.NoResultsError, fn ->
        Organizations.get_organization!(scope2, org.id)
      end
    end
  end

  describe "get_organization_by_slug/2" do
    test "returns organization if user is a member" do
      scope = user_scope_fixture()
      {:ok, org} = Organizations.create_organization(scope, %{name: "My Org"})

      assert Organizations.get_organization_by_slug(scope, org.slug) == org
    end

    test "returns nil if user is not a member" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      {:ok, org} = Organizations.create_organization(scope1, %{name: "My Org"})

      assert Organizations.get_organization_by_slug(scope2, org.slug) == nil
    end

    test "returns nil if organization does not exist" do
      scope = user_scope_fixture()

      assert Organizations.get_organization_by_slug(scope, "nonexistent-slug") == nil
    end
  end

  describe "update_organization/2" do
    test "owner can update organization" do
      scope = user_scope_fixture()
      {:ok, org} = Organizations.create_organization(scope, %{name: "Old Name"})
      org_scope = user_scope_fixture(scope.user, org)

      assert {:ok, updated} =
               Organizations.update_organization(org_scope, %{name: "New Name"})

      assert updated.name == "New Name"
    end

    test "non-owner cannot update organization" do
      owner_scope = user_scope_fixture()
      member = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, member, :member)

      member_org_scope = user_scope_fixture(member, org)

      assert {:error, :unauthorized} =
               Organizations.update_organization(member_org_scope, %{name: "Hacked"})
    end
  end

  describe "delete_organization/1" do
    test "owner can delete organization" do
      scope = user_scope_fixture()
      {:ok, org} = Organizations.create_organization(scope, %{name: "My Org"})
      org_scope = user_scope_fixture(scope.user, org)

      assert {:ok, _} = Organizations.delete_organization(org_scope)

      assert_raise Ecto.NoResultsError, fn ->
        Organizations.get_organization!(scope, org.id)
      end
    end

    test "non-owner cannot delete organization" do
      owner_scope = user_scope_fixture()
      member = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, member, :member)

      member_org_scope = user_scope_fixture(member, org)

      assert {:error, :unauthorized} = Organizations.delete_organization(member_org_scope)
    end
  end

  describe "membership management" do
    test "add_member/3 adds user to organization" do
      owner_scope = user_scope_fixture()
      new_user = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      new_user_org_scope = user_scope_fixture(new_user, org)

      refute Organizations.member?(new_user_org_scope)

      {:ok, membership} = Organizations.add_member(owner_org_scope, new_user, :member)

      assert membership.role == :member
      assert Organizations.member?(new_user_org_scope)
      refute Organizations.owner?(new_user_org_scope)
    end

    test "add_member/3 prevents duplicate memberships" do
      owner_scope = user_scope_fixture()
      new_user = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, new_user, :member)

      assert {:error, changeset} = Organizations.add_member(owner_org_scope, new_user, :member)
      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "remove_member/2 removes user from organization" do
      owner_scope = user_scope_fixture()
      new_user = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      new_user_org_scope = user_scope_fixture(new_user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, new_user, :member)

      assert Organizations.member?(new_user_org_scope)

      {:ok, _} = Organizations.remove_member(owner_org_scope, new_user)

      refute Organizations.member?(new_user_org_scope)
    end

    test "update_member_role/3 changes role" do
      owner_scope = user_scope_fixture()
      new_user = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      new_user_org_scope = user_scope_fixture(new_user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, new_user, :member)

      refute Organizations.owner?(new_user_org_scope)

      {:ok, _} = Organizations.update_member_role(owner_org_scope, new_user, :owner)

      assert Organizations.owner?(new_user_org_scope)
    end

    test "list_members/1 returns all members" do
      owner_scope = user_scope_fixture()
      member1 = user_fixture()
      member2 = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, member1, :member)
      {:ok, _} = Organizations.add_member(owner_org_scope, member2, :member)

      members = Organizations.list_members(owner_org_scope)

      assert length(members) == 3
    end
  end

  describe "sync_oidc_memberships/2" do
    test "adds exact organization slugs as idempotent OIDC members" do
      user_scope = user_scope_fixture()
      owner_scope = user_scope_fixture()

      {:ok, organization} =
        Organizations.create_organization(owner_scope, %{name: "Managed Org", slug: "managed-org"})

      assert {:ok, %{created: 1, removed: 0}} =
               Organizations.sync_oidc_memberships(user_scope, [
                 "managed-org",
                 "unknown-org",
                 "managed-org"
               ])

      membership =
        Organizations.get_membership(
          user_scope_fixture(user_scope.user, organization),
          user_scope.user
        )

      assert membership.role == :member
      assert membership.provisioner == :oidc

      assert {:ok, %{created: 0, removed: 0}} =
               Organizations.sync_oidc_memberships(user_scope, ["managed-org", "managed-org"])
    end

    test "removes stale OIDC members while preserving manual members and owners" do
      user_scope = user_scope_fixture()
      owner_scope = user_scope_fixture()

      {:ok, oidc_organization} =
        Organizations.create_organization(owner_scope, %{name: "OIDC Org", slug: "oidc-org"})

      {:ok, manual_organization} =
        Organizations.create_organization(owner_scope, %{name: "Manual Org", slug: "manual-org"})

      owner_organization_scope = user_scope_fixture(owner_scope.user, manual_organization)

      {:ok, manual_membership} =
        Organizations.add_member(owner_organization_scope, user_scope.user)

      {:ok, owned_organization} =
        Organizations.create_organization(user_scope, %{name: "Owned Org", slug: "owned-org"})

      assert {:ok, %{created: 1, removed: 0}} =
               Organizations.sync_oidc_memberships(user_scope, ["oidc-org"])

      assert {:ok, %{created: 0, removed: 1}} =
               Organizations.sync_oidc_memberships(user_scope, [])

      assert Organizations.get_membership(
               user_scope_fixture(user_scope.user, oidc_organization),
               user_scope.user
             ) == nil

      assert Organizations.get_membership(
               user_scope_fixture(user_scope.user, manual_organization),
               user_scope.user
             ).provisioner == :manual

      assert Organizations.get_membership(
               user_scope_fixture(user_scope.user, owned_organization),
               user_scope.user
             ).role == :owner

      assert manual_membership.provisioner == :manual
    end

    test "retains an OIDC membership promoted to owner after its claim is removed" do
      user_scope = user_scope_fixture()
      owner_scope = user_scope_fixture()

      {:ok, organization} =
        Organizations.create_organization(owner_scope, %{
          name: "Promoted Org",
          slug: "promoted-org"
        })

      owner_organization_scope = user_scope_fixture(owner_scope.user, organization)

      assert {:ok, %{created: 1, removed: 0}} =
               Organizations.sync_oidc_memberships(user_scope, ["promoted-org"])

      assert {:ok, _membership} =
               Organizations.update_member_role(owner_organization_scope, user_scope.user, :owner)

      assert {:ok, %{created: 0, removed: 0}} =
               Organizations.sync_oidc_memberships(user_scope, [])

      membership =
        Organizations.get_membership(
          user_scope_fixture(user_scope.user, organization),
          user_scope.user
        )

      assert membership.role == :owner
      assert membership.provisioner == :oidc
    end

    test "serializes concurrent synchronization for one user" do
      Sandbox.unboxed_run(Repo, fn ->
        user_scope = user_scope_fixture()
        owner_scope = user_scope_fixture()

        {:ok, first_organization} =
          Organizations.create_organization(owner_scope, %{name: "First Org", slug: "first-org"})

        {:ok, second_organization} =
          Organizations.create_organization(owner_scope, %{name: "Second Org", slug: "second-org"})

        try do
          tasks = lock_user_and_start_synchronizations(user_scope)

          results = Enum.map(tasks, &Task.await(&1, 1_000))
          assert Enum.all?(results, &match?({:ok, _}, &1))

          memberships =
            user_scope.user.id
            |> Membership.for_user()
            |> Repo.all()

          assert Enum.count(
                   memberships,
                   &match?(%Membership{provisioner: :oidc, role: :member}, &1)
                 ) ==
                   1

          assert Enum.any?(memberships, fn membership ->
                   membership.organization_id in [first_organization.id, second_organization.id]
                 end)
        after
          Repo.delete!(first_organization)
          Repo.delete!(second_organization)
          Repo.delete!(user_scope.user)
          Repo.delete!(owner_scope.user)
        end
      end)
    end
  end

  describe "role checks" do
    test "owner?/1 returns true only for owners" do
      owner_scope = user_scope_fixture()
      member = user_fixture()
      outsider = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, member, :member)

      member_org_scope = user_scope_fixture(member, org)
      outsider_org_scope = user_scope_fixture(outsider, org)

      assert Organizations.owner?(owner_org_scope)
      refute Organizations.owner?(member_org_scope)
      refute Organizations.owner?(outsider_org_scope)
    end

    test "member?/1 returns true for any role" do
      owner_scope = user_scope_fixture()
      member = user_fixture()
      outsider = user_fixture()

      {:ok, org} = Organizations.create_organization(owner_scope, %{name: "My Org"})
      owner_org_scope = user_scope_fixture(owner_scope.user, org)
      {:ok, _} = Organizations.add_member(owner_org_scope, member, :member)

      member_org_scope = user_scope_fixture(member, org)
      outsider_org_scope = user_scope_fixture(outsider, org)

      assert Organizations.member?(owner_org_scope)
      assert Organizations.member?(member_org_scope)
      refute Organizations.member?(outsider_org_scope)
    end
  end

  defp lock_user_and_start_synchronizations(user_scope) do
    parent = self()

    {:ok, tasks} =
      Repo.transaction(fn ->
        User
        |> User.locked_for_update()
        |> Repo.get!(user_scope.user.id)

        tasks =
          Enum.map(
            [["first-org"], ["second-org"]],
            &start_synchronization(parent, user_scope, &1)
          )

        assert_receive {:ready, _task_pid}, 1_000
        assert_receive {:ready, _task_pid}, 1_000
        Enum.each(tasks, &send(&1.pid, :sync))
        refute_receive {:finished, _task_pid}, 100
        tasks
      end)

    tasks
  end

  defp start_synchronization(parent, user_scope, organization_slugs) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        send(parent, {:ready, self()})
        await_synchronization(parent, user_scope, organization_slugs)
      end)
    end)
  end

  defp await_synchronization(parent, user_scope, organization_slugs) do
    receive do
      :sync ->
        result = Organizations.sync_oidc_memberships(user_scope, organization_slugs)
        send(parent, {:finished, self()})
        result
    after
      1_000 -> raise "timed out waiting to synchronize memberships"
    end
  end
end
