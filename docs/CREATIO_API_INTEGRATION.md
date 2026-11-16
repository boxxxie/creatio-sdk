# Creatio CRM API & Integration Guide

## Official API Documentation
The primary reference for the Creatio CRM API is the comprehensive Postman documentation:
* **Online Postman Documentation:** [Creatio API Postman Documentation](https://documenter.getpostman.com/view/10204500/SztHX5Qb?version=latest)
* **Offline Postman Collection:** [`docs/creatio_api_collection.json`](https://github.com/boxxxie/creatio-sdk/blob/master/docs/creatio_api_collection.json) (included in the GitHub repository)
* **Official Postman Environment:** [Creatio.postman_environment.zip](https://academy.creatio.com/sites/default/files/documents/downloads/SDK/Creatio.postman_environment.zip)
* **Creatio Academy:** [Creatio Academy Documentation](https://academy.creatio.com/)

## Integration Overview
Creatio (formerly bpm'online) is used as an authoritative source of truth for:
*   Membership status
*   Organization status and category
*   Renewal dates
*   Core contacts

The integration with Creatio is typically read-heavy, pulling contact and account records into external client applications while maintaining local platform state.

### Defense-in-Depth: Read-Only Client Mode
When using Creatio strictly as a read-replica or data source, the SDK supports configuring `read_only: true` (or via environment variable `CREATIO_READ_ONLY=true`). In this mode:
* Read queries (`list`, `get`, `count`, `select_query`) function normally.
* Mutations (`create`, `update`, `delete`, field updates, mutating batches, DataService writes) are blocked locally, returning `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}`.
* Network requests for any mutation methods (`POST`, `PATCH`, `PUT`, `DELETE` outside of safe auth and `SelectQuery` paths) are rejected by a client-level HTTP middleware guard.

## API Protocol
Creatio exposes data via the **OData 4** (Open Data Protocol) standard.
*   **Base OData 4 Endpoint:** `{CreatioURL}/0/odata/{ObjectName}`
*   *Note: OData 3 (`EntityDataService.svc`) is legacy and does not support modern Assembly packages.*

## Authentication
Before calling OData endpoints, the client must authenticate. The API supports two primary methods:

### 1. Cookie-Based (Forms) Authentication
Typically used for backend/server-to-server integrations where OAuth is not configured:
1.  **Login:** Send a `POST` request to `{CreatioURL}/ServiceModel/AuthService.svc/Login` with a JSON body:
    ```json
    {
      "UserName": "IntegrationUser",
      "UserPassword": "Password123"
    }
    ```
2.  **Cookies:** Extract the `.ASPXAUTH` and `BPMLOADER` cookies from the response headers.
3.  **BPMCSRF Token:** Extract the value of the `BPMCSRF` cookie and include it as a custom HTTP header (`BPMCSRF: <value>`) in all subsequent `POST`, `PATCH`, and `DELETE` requests.

### 2. OAuth 2.0 (Recommended)
Uses the Creatio Identity Service (Client Credentials grant):
*   **Token Endpoint:** `{IdentityServiceURL}/connect/token`
*   **Payload:** `client_id`, `client_secret`, `grant_type=client_credentials`
*   Token is included in the `Authorization: Bearer <token>` header on all subsequent requests.

## Key Objects & Data Mapping

| Creatio Object | Typical Application Entity | Description / Usage |
| :--- | :--- | :--- |
| `Contact` | `User` / `Profile` | Member identity, full name, email, phone, title, core contact info. |
| `Account` | `Organization` / `Company` | Firm name, account category, industry, active status. |
| `AccountContact` | Membership Link | Bridge table linking Contacts to their Accounts/Organizations. |

## Querying Data (OData 4 Examples)

**Filter Contacts by Name:**
```http
GET {{BaseURI}}/0/odata/Contact?$filter=Name eq 'John Smith'
```

**Filter Accounts by Category:**
```http
GET {{BaseURI}}/0/odata/Account?$filter=AccountCategory/Name eq 'Customer'
```

**Select Specific Fields:**
```http
GET {{BaseURI}}/0/odata/Contact?$select=Id,Name,Email,MobilePhone,JobTitle
```

**Pagination (Important for large data syncs):**
Creatio limits the number of records returned per request. Use `$top` and `$skip` to paginate:
```http
GET {{BaseURI}}/0/odata/Contact?$top=100&$skip=200
```
*(Note: OData 4 in Creatio does not support the `in` operator; use multiple `or` conditions instead).*

In the SDK, `Creatio.stream(client, "Contact", page_size: 100, skip: 200)` (yielding `{:ok, record}` / `{:error, error}` tuples) and `Creatio.stream!(client, "Contact", page_size: 100, skip: 200)` (yielding plain `record` maps) automate this with lazy Elixir streams and support an initial `:skip` offset for resuming interrupted queries.

**Batch Requests:**
Creatio supports OData batching via `/0/odata/$batch` using multipart MIME bodies or JSON batch format.
