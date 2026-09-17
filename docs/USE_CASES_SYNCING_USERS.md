# Use Case: Syncing Creatio Users to a Local Database

This guide demonstrates how to use the Creatio SDK to synchronize "Contact" and "Account" records from a live Creatio instance into an independent, local application database. 

Syncing data securely and efficiently often involves two phases:
1. **Initial Full Backfill**: Pulling all existing records.
2. **Incremental Delta Syncs**: Periodically fetching only the records that have changed since the last sync.

## 1. Setting Up the Client

First, initialize the SDK client with your Creatio credentials. In a real application, these will usually come from environment variables.

```elixir
# Load from environment variables (configured via .env or similar)
base_url = System.fetch_env!("CREATIO_BASE_URL")
username = System.fetch_env!("CREATIO_USERNAME")
password = System.fetch_env!("CREATIO_PASSWORD")

# Initialize client
client = Creatio.Client.new(
  base_url: base_url,
  auth_mode: :forms
)

# Authenticate (This obtains the necessary auth cookies, like BPMCSRF)
{:ok, client} = Creatio.Auth.login_forms(client, username, password)
```

## 2. Initial Full Backfill (Streaming)

When pulling a large amount of data (e.g., thousands of Contacts), it's dangerous to fetch them all at once into memory. Creatio caps responses to limit overhead. To handle this, use the SDK's `Creatio.stream/3` which provides **OData lazy streaming pagination**.

Using Elixir Streams, we can process pages of Contacts iteratively, inserting them into our DB as they arrive.

```elixir
# Stream Contacts from Creatio in chunks (e.g., 100 per page)
contacts_stream = Creatio.stream(client, "Contact",
  select: "Id,Name,Email,ModifiedOn,AccountId",
  expand: "Account($select=Id,Name)" # Eager-load the related Account!
)

# Process the stream
Stream.each(contacts_stream, fn contact ->
  # 'contact' is an individual record from the OData stream
  # Insert or update the contact in your local DB (e.g., via Ecto)
  # MyApp.Repo.insert_or_update!(...)
  IO.puts("Syncing Contact: #{contact["Name"]} (Email: #{contact["Email"]})")
  
  # You can also handle the expanded account
  if account = contact["Account"] do
    IO.puts("  Belongs to Account: #{account["Name"]}")
  end
end)
|> Stream.run() # Execute the lazy stream
```

*Tip: Expanding relationships (`$expand=Account`) minimizes the number of HTTP requests, avoiding the N+1 query problem during syncs.*

## 3. Incremental Delta Syncs (Scheduled Job)

After the initial backfill, you don't want to re-download everything. A scheduled background worker (like Oban) can routinely fetch only records modified since the last successful sync.

We achieve this using OData `$filter` on the `ModifiedOn` field.

```elixir
defmodule MyApp.Workers.CreatioDeltaSync do
  @moduledoc """
  A background worker that runs every X minutes to fetch recently changed contacts.
  """
  
  def perform() do
    client = get_authenticated_client()
    
    # 1. Look up the timestamp of the last successful sync in your DB
    last_sync_timestamp = MyApp.SyncLogs.get_last_sync_time() 
    # e.g., ~U[2023-10-27 15:30:00Z]
    
    # 2. Format the timestamp for OData
    # Creatio OData expects datetime formats like: datetime'2023-10-27T15:30:00'
    formatted_time = NaiveDateTime.to_iso8601(last_sync_timestamp)
    
    # 3. Query Contacts modified AFTER the last sync
    query = [
      select: "Id,Name,Email,ModifiedOn",
      filter: "ModifiedOn gt datetime'#{formatted_time}'",
      orderby: "ModifiedOn asc"
    ]
    
    # We can use the stream here as well in case there are many updates
    Creatio.stream(client, "Contact", query)
    |> Stream.each(fn chunk ->
      MyApp.Accounts.bulk_upsert_contacts(chunk)
    end)
    |> Stream.run()
    
    # 4. Update the sync log timestamp
    MyApp.SyncLogs.record_sync_success(DateTime.utc_now())
  end
  
  defp get_authenticated_client() do
    client = Creatio.Client.new(
      base_url: System.get_env("CREATIO_BASE_URL"),
      auth_mode: :forms
    )
    {:ok, client} = Creatio.Auth.login_forms(
      client,
      System.get_env("CREATIO_USERNAME"),
      System.get_env("CREATIO_PASSWORD")
    )
    client
  end
end
```

## 4. Handling Worker Resilience

When syncing in a background job, you might face temporary network issues or expired authentication cookies. 

### Catching Auth Expirations

If the Creatio session expires, you will start receiving 401 Unauthorized or 403 Forbidden responses. Ensure your sync worker knows how to re-authenticate and retry.

```elixir
def fetch_data_with_retry(client, entity, query) do
  case Creatio.list(client, entity, query) do
    {:ok, data} -> 
      {:ok, data}
      
    {:error, %Creatio.Error{status: 401}} ->
      # Auth expired, re-authenticate and try once more
      {:ok, new_client} = Creatio.Auth.login_forms(client, System.get_env("CREATIO_USERNAME"), System.get_env("CREATIO_PASSWORD"))
      Creatio.list(new_client, entity, query)
      
    {:error, reason} ->
      # Log error and fail the background job so it can be retried later
      require Logger
      Logger.error("Creatio API Error: #{inspect(reason)}")
      {:error, reason}
  end
end
```

### Dealing with Deleted Records

Creatio doesn't usually expose "DeletedOn" via OData because the record is removed entirely. To properly sync deletions, you have a few options:
1. **Soft Deletes in Creatio:** Ask the Creatio admins to implement soft-deletes (adding an `IsActive` or `IsDeleted` boolean column). Your delta sync can then just filter by `ModifiedOn` and check `IsDeleted == true`.
2. **Periodic Reconciliation:** Run a nightly script that fetches *only the IDs* (`$select=Id`) of all records in Creatio, and compares them against your DB's IDs to find which ones were dropped.

## Summary

By leveraging the SDK's built-in `Creatio.stream/3` and robust OData filtering, a sync engine between your database and Creatio is both safe for memory consumption and lightweight on the network.
