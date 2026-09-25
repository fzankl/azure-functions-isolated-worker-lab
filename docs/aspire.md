# Closing Picture: The Optional Aspire Stage

**Tag:** `aspire-optional`

> **Article reference:** Section "Nine Steps, and the Order Matters", last paragraph, in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration). This document details the restore order and the relevant sources.

This stage is intentionally not part of this repository's main path. It builds on the target state and does not modify the code of the Function App.

## Structure

`aspire/OrderProcessor.AppHost` references `src/OrderProcessor/OrderProcessor.csproj` and provisions two resources:

```csharp
var storage = builder.AddAzureStorage("storage")
    .RunAsEmulator();

var queues = storage.AddQueues("queues");

builder.AddAzureFunctionsProject<Projects.OrderProcessor>("orderprocessor")
    .WithHostStorage(storage)
    .WithReference(queues);
```

`RunAsEmulator()` has Aspire start and manage an Azurite container itself. `WithHostStorage(storage)` connects the Function App's `AzureWebJobsStorage` to this emulator, and `WithReference(queues)` passes the connection information for the queue binding.

`WithHostStorage` is optional. Without it, `AddAzureFunctionsProject` adds a storage resource of its own for the Functions host, named `funcstorage` plus a short hash, and Aspire starts a second Azurite container for it. The host then writes its `azure-webjobs-hosts` data to that second emulator instead of the shared one; `POST /api/orders` still answers 200. This repository calls `WithHostStorage` so that the host and the queue share one emulator.

## Trying It Out

`dotnet run` in the directory `aspire/OrderProcessor.AppHost` starts the Azurite container and the Function App. The Function App does not run on port 7071, but on a port that Aspire assigns anew each time it starts. This port is displayed in the dashboard (URL in the console output) for the resource `orderprocessor`. By replacing `localhost:7071` in `http/target-net10.http` with this port, you will receive the same responses for `POST /api/orders` and `GET /api/diagnostics/log-filters` as in the target state, without modifying the Function App's code.

## The Build SDK Is Not Visible to Aspire

`AddAzureFunctionsProject<Projects.OrderProcessor>` accepts a project with `Azure.Functions.Sdk` unchanged. The prerequisite for integration is the isolated execution model, not a specific build SDK.

A peculiarity only affects this path. If the AppHost is built without the Functions project being restored independently beforehand, the build will report:

```
warning AZFW0108: The Functions extensions project was not restored prior to build.
Falling back to restore-during-build for the Functions extensions project.
This may cause issues in some build environments.
```

`Azure.Functions.Sdk` creates a helper project `obj/azure_functions/azure_functions.g.csproj` during the restore process. A `dotnet restore` from the AppHost does not include it in the restore graph, even when explicitly called. Consequently, only `OrderProcessor.AppHost.csproj` and `OrderProcessor.csproj` appear in the restore log. The build then restores it as a side effect and issues a warning.

Microsoft describes this behavior under AZFW0108 for solution and traversal projects: The post-restore hook that creates the helper project only runs when the Functions project is restored directly. An AppHost that includes the Functions project via `ProjectReference` behaves the same way.

The solution is to restore the Functions project directly once, and then build the AppHost.

```bash
dotnet restore src/OrderProcessor/OrderProcessor.csproj
dotnet build aspire/OrderProcessor.AppHost/OrderProcessor.AppHost.csproj
```

The warning is not fatal; the AppHost will still start with it.

## Cleanup

After stopping the AppHost (Ctrl+C), the `storage-<id>` container started by Aspire remains. If you removed `WithHostStorage`, a `funcstorage<hash>-<id>` container remains as well; adjust the name filter below accordingly.

```bash
docker ps -a --format "{{.Names}}" | grep '^storage-' | xargs -r docker rm -f
```

```powershell
docker ps -a --format "{{.Names}}" | Where-Object { $_ -like 'storage-*' } | ForEach-Object { docker rm -f $_ }
```

## Sources

- [Aspire: Azure Functions integration - Get started](https://aspire.dev/integrations/cloud/azure/azure-functions/azure-functions-get-started/)
- [Aspire: Set up Azure Functions in the AppHost](https://aspire.dev/integrations/cloud/azure/azure-functions/azure-functions-host/)
- [AZFW0108: Extension bundle not restored before build](https://learn.microsoft.com/en-us/azure/azure-functions/errors-diagnostics/msbuild-sdk-rules/azfw0108)