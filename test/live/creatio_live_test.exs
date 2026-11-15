defmodule Creatio.LiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  alias Creatio.{Batch, DataService, Error, LiveHelper, OData, OData3}
  alias Creatio.OData.Query

  describe "Phase 1: Live authentication & client setup" do
    test "initializes sandbox client with read_only: true enforced by default" do
      LiveHelper.with_live_client([], fn client ->
        assert client.base_url == LiveHelper.base_url()
        assert client.read_only == true
      end)
    end

    test "authenticates via OAuth 2.0 client credentials and probes identity endpoints" do
      LiveHelper.with_live_client([auth: :oauth], fn client ->
        assert client.auth_mode == :bearer
        assert is_binary(client.auth_token) and client.auth_token != ""
        assert client.read_only == true

        case Creatio.oauth_health_check(client) do
          {:ok, health} ->
            assert is_map(health) or is_binary(health)

          {:error, %Error{} = err} ->
            if LiveHelper.waf_or_network_error?(err), do: :ok, else: flunk(Exception.message(err))
        end

        case Creatio.openid_configuration(client) do
          {:ok, config} ->
            assert is_map(config)
            assert is_binary(config["issuer"])

          {:error, %Error{} = err} ->
            if LiveHelper.waf_or_network_error?(err), do: :ok, else: flunk(Exception.message(err))
        end
      end)
    end

    test "authenticates via Forms Auth and captures cookies + BPMCSRF" do
      LiveHelper.with_live_client([auth: :forms], fn client ->
        assert client.auth_mode == :forms
        assert is_binary(client.cookie) and client.cookie != ""
        assert client.read_only == true
      end)
    end
  end

  describe "Phase 2: Read-only protocol verification" do
    test "verifies OData 4 list/3, count/3 (:path and :top_zero), get/4, and get_field/5" do
      LiveHelper.with_live_client([], fn client ->
        entity = LiveHelper.live_entity()

        case OData.list(client, entity, top: 2, count: true) do
          {:ok, %{records: records, count: inline_count}} ->
            assert is_list(records)
            assert length(records) <= 2
            assert is_integer(inline_count)

            assert {:ok, path_count} = OData.count(client, entity, strategy: :path)
            assert {:ok, top_zero_count} = OData.count(client, entity, strategy: :top_zero)
            assert is_integer(path_count) and path_count >= 0
            assert is_integer(top_zero_count) and top_zero_count >= 0

            verify_single_entity_and_field(client, entity, records)

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "OData.list/3")
        end
      end)
    end

    test "verifies Creatio.OData.Query builders ($select, $filter, $orderby, $expand, GUID literal)" do
      LiveHelper.with_live_client([], fn client ->
        entity = LiveHelper.live_entity()

        base_query =
          Query.new(entity)
          |> Query.select(["Id", "Name"])
          |> Query.order_by("Id asc")
          |> Query.top(2)

        case OData.list(client, base_query) do
          {:ok, records} when is_list(records) ->
            verify_query_filters(client, entity, records)

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "OData Query execution")
        end
      end)
    end

    test "verifies OData.get_field_value/5 raw retrieval and into: streaming sink" do
      LiveHelper.with_live_client([], fn client ->
        entity = LiveHelper.live_entity()

        case OData.list(client, entity, select: ["Id", "Name"], top: 1) do
          {:ok, [%{"Id" => id} | _]} ->
            case OData.get_field_value(client, entity, id, "Name") do
              {:ok, val} -> assert is_nil(val) or is_binary(val)
              {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "OData.get_field_value/5")
            end

            tmp_path =
              Path.join(
                System.tmp_dir!(),
                "creatio_live_field_#{System.unique_integer([:positive])}.bin"
              )

            on_exit(fn -> File.rm(tmp_path) end)

            case OData.get_field_value(client, entity, id, "Name", into: File.stream!(tmp_path)) do
              {:ok, %File.Stream{}} ->
                assert File.exists?(tmp_path)

              {:ok, nil} ->
                :ok

              {:error, %Error{} = err} ->
                LiveHelper.skip_or_fail!(err, "OData.get_field_value/5 into")
            end

          {:ok, []} ->
            :ok

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "OData.list/3 for field value")
        end
      end)
    end

    test "compares OData.stream/3 offset pagination with cursor_field keyset pagination" do
      LiveHelper.with_live_client([], fn client ->
        entity = LiveHelper.live_entity()
        {seeded_id, cleanup_client} = maybe_seed_record_for_stream(client, entity)

        try do
          offset_results =
            OData.stream(client, entity,
              page_size: 2,
              max_records: 4,
              orderby: "Id asc",
              select: ["Id"]
            )
            |> Enum.to_list()

          keyset_results =
            OData.stream(client, entity,
              page_size: 2,
              max_records: 4,
              cursor_field: "Id",
              select: ["Id"]
            )
            |> Enum.to_list()

          case {List.last(offset_results), List.last(keyset_results)} do
            {{:error, %Error{} = err}, _} ->
              LiveHelper.skip_or_fail!(err, "OData.stream/3")

            {_, {:error, %Error{} = err}} ->
              LiveHelper.skip_or_fail!(err, "OData.stream/3")

            _ ->
              offset_records = for {:ok, rec} <- offset_results, do: rec
              keyset_records = for {:ok, rec} <- keyset_results, do: rec

              try do
                bang_records =
                  OData.stream!(client, entity, page_size: 2, max_records: 2, select: ["Id"])
                  |> Enum.to_list()

                assert is_list(bang_records)
              rescue
                e in Error -> LiveHelper.skip_or_fail!(e, "OData.stream!/3")
              end

              offset_ids = Enum.map(offset_records, & &1["Id"])
              keyset_ids = Enum.map(keyset_records, & &1["Id"])

              if offset_ids == [] and not LiveHelper.mutations_allowed?() do
                LiveHelper.log_skip_once(
                  "Entity #{entity} has no records to compare offset vs keyset pagination (set CREATIO_LIVE_ALLOW_MUTATIONS=true to seed a temporary record)"
                )
              else
                assert offset_ids != []
                assert offset_ids == keyset_ids
                assert length(offset_ids) == length(Enum.uniq(offset_ids))
              end
          end
        after
          if seeded_id && cleanup_client do
            _ = OData.delete(cleanup_client, entity, seeded_id)
          end
        end
      end)
    end

    test "verifies OData3.list/3, OData3.count/3, OData3.stream/3, and DataService.select_query/3" do
      LiveHelper.with_live_client([], fn client ->
        entity = LiveHelper.live_entity()

        case OData3.list(client, entity, top: 2) do
          {:ok, records} ->
            assert is_list(records)
            assert length(records) <= 2

            assert {:ok, o3_path_count} = OData3.count(client, entity, strategy: :path)
            assert {:ok, o3_query_count} = OData3.count(client, entity, strategy: :query)
            assert is_integer(o3_path_count) and is_integer(o3_query_count)

            streamed =
              OData3.stream(client, entity, page_size: 2, max_records: 2) |> Enum.to_list()

            assert is_list(streamed)
            assert Enum.all?(streamed, &match?({:ok, %{}}, &1))

            streamed_bang =
              OData3.stream!(client, entity, page_size: 2, max_records: 2) |> Enum.to_list()

            assert is_list(streamed_bang)
            assert Enum.all?(streamed_bang, &is_map/1)

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "OData3 read operations")
        end

        select_payload = %{
          "RootSchemaName" => entity,
          "rowCount" => 2,
          "columns" => %{
            "items" => %{
              "Id" => %{"expression" => %{"columnPath" => "Id"}},
              "Name" => %{"expression" => %{"columnPath" => "Name"}}
            }
          }
        }

        case DataService.select_query(client, select_payload) do
          {:ok, res} ->
            assert is_map(res)
            assert is_list(res["rows"])

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "DataService.select_query/3")
        end
      end)
    end

    test "verifies read-only $batch (JSON & :multipart) and ReadOnlyMode local guard" do
      LiveHelper.with_live_client([], fn client ->
        entity = LiveHelper.live_entity()

        assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
                 OData.create(client, entity, %{"Name" => "Blocked"})

        assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
                 OData3.create(client, entity, %{"Name" => "Blocked"})

        assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
                 DataService.insert_query(client, %{"RootSchemaName" => entity})

        mutating_batch = Batch.new() |> Batch.add_create(entity, %{"Name" => "Blocked"})

        assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
                 Batch.execute(client, mutating_batch)

        read_batch =
          Batch.new(continue_on_error: true)
          |> Batch.add_get("#{entity}?$top=1")
          |> Batch.add_get("#{entity}/$count")

        case Batch.execute(client, read_batch, format: :json) do
          {:ok, responses} ->
            assert length(responses) == 2
            assert Enum.all?(responses, &Batch.Response.success?/1)

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "Read-only JSON Batch")
        end

        case Batch.execute(client, read_batch, format: :multipart) do
          {:ok, responses} ->
            assert length(responses) == 2
            assert Enum.all?(responses, &Batch.Response.success?/1)

          {:error, %Error{} = err} ->
            LiveHelper.skip_or_fail!(err, "Read-only multipart Batch")
        end
      end)
    end
  end

  describe "Phase 3: Opt-in mutation & changeset roundtrip" do
    test "verifies opt-in OData CRUD (return: :minimal and :representation), $batch changeset, and cleanup" do
      if LiveHelper.mutations_allowed?() do
        LiveHelper.with_live_client([mutable: true], fn client ->
          entity = LiveHelper.live_entity()
          suffix = System.unique_integer([:positive])

          # 1. Create with return: :representation
          rep_attrs = %{"Name" => "CreatioSDK LiveTest Rep #{suffix}"}

          case OData.create(client, entity, rep_attrs, return: :representation) do
            {:ok, %{"Id" => rep_id}} ->
              LiveHelper.register_cleanup(client, entity, rep_id)

              assert :ok ==
                       OData.update(
                         client,
                         entity,
                         rep_id,
                         %{"Name" => "CreatioSDK LiveTest Updated #{suffix}"},
                         return: :minimal
                       )

              assert :ok ==
                       OData.update_field(
                         client,
                         entity,
                         rep_id,
                         "Name",
                         "CreatioSDK Field Updated #{suffix}"
                       )

              assert :ok == OData.delete(client, entity, rep_id)
              assert {:error, %Error{status: 404}} = OData.get(client, entity, rep_id)

            {:error, %Error{} = err} ->
              LiveHelper.skip_or_fail!(err, "Opt-in OData.create/4")
          end

          # 2. Create with return: :minimal (`204` header extraction) + $batch changeset
          min_attrs = %{"Name" => "CreatioSDK LiveTest Min #{suffix}"}

          case OData.create(client, entity, min_attrs, return: :minimal) do
            {:ok, %{"Id" => min_id} = created} ->
              LiveHelper.register_cleanup(client, entity, min_id)
              assert is_binary(created["@odata.id"])

              changeset =
                Batch.new()
                |> Batch.add_update(
                  entity,
                  min_id,
                  %{"Name" => "CreatioSDK Batch Updated #{suffix}"},
                  atomicity_group: "live_g1"
                )
                |> Batch.add_delete(entity, min_id, atomicity_group: "live_g1")

              assert {:ok, batch_responses} = Batch.execute(client, changeset)
              assert Enum.all?(batch_responses, &Batch.Response.success?/1)

            {:ok, other} ->
              flunk("Expected Id in return: :minimal response, got: #{inspect(other)}")

            {:error, %Error{} = err} ->
              LiveHelper.skip_or_fail!(err, "Opt-in OData.create/4 return: :minimal")
          end
        end)
      else
        LiveHelper.log_skip_once(
          "Opt-in mutations disabled (set CREATIO_LIVE_ALLOW_MUTATIONS=true to enable Phase 3 CRUD/Batch changeset tests)"
        )
      end
    end
  end

  defp maybe_seed_record_for_stream(client, entity) do
    with {:ok, []} <- OData.list(client, entity, top: 1, select: ["Id"]),
         true <- LiveHelper.mutations_allowed?(),
         {:ok, mutable_client} <- LiveHelper.connect_live_client(mutable: true),
         suffix = System.unique_integer([:positive]),
         {:ok, %{"Id" => id}} <-
           OData.create(mutable_client, entity, %{"Name" => "CreatioSDK StreamSeed #{suffix}"}) do
      {id, mutable_client}
    else
      _ -> {nil, nil}
    end
  end

  defp verify_single_entity_and_field(_client, _entity, []), do: :ok

  defp verify_single_entity_and_field(client, entity, [%{"Id" => id} = first | _]) do
    case OData.get(client, entity, id) do
      {:ok, fetched} -> assert fetched["Id"] == id
      {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "OData.get/4")
    end

    if Map.has_key?(first, "Name") do
      case OData.get_field(client, entity, id, "Name") do
        {:ok, _name} -> :ok
        {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "OData.get_field/5")
      end
    end

    if entity == "Contact" and Map.has_key?(first, "AccountId") and first["AccountId"] do
      case OData.get_navigation(client, entity, id, "Account") do
        {:ok, _account} -> :ok
        {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "OData.get_navigation/5")
      end
    end

    :ok
  end

  defp verify_query_filters(_client, _entity, []), do: :ok

  defp verify_query_filters(client, entity, [%{"Id" => id} = first | _]) do
    guid_q =
      Query.new(entity)
      |> Query.select(["Id", "Name"])
      |> Query.filter_guid("Id", id)

    case OData.list(client, guid_q) do
      {:ok, matches} -> assert Enum.any?(matches, &(&1["Id"] == id))
      {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "Query.filter_guid/3")
    end

    in_q = Query.new(entity) |> Query.select(["Id"]) |> Query.filter_in_ids("Id", [id])

    case OData.list(client, in_q) do
      {:ok, matches} -> assert Enum.any?(matches, &(&1["Id"] == id))
      {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "Query.filter_in_ids/3")
    end

    if is_binary(first["Name"]) and String.length(first["Name"]) >= 2 do
      needle = String.slice(first["Name"], 0, 2)

      contains_q =
        Query.new(entity)
        |> Query.select(["Id"])
        |> Query.filter_contains("Name", needle)
        |> Query.top(2)

      case OData.list(client, contains_q) do
        {:ok, matches} -> assert is_list(matches)
        {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "Query.filter_contains/3")
      end
    end

    if entity == "Contact" do
      expand_q =
        Query.new("Contact")
        |> Query.select(["Id", "Name"])
        |> Query.expand("Account($select=Id,Name)")
        |> Query.top(1)

      case OData.list(client, expand_q) do
        {:ok, expanded} -> assert is_list(expanded)
        {:error, %Error{} = err} -> LiveHelper.skip_or_fail!(err, "Query.expand/2")
      end
    end

    :ok
  end
end
