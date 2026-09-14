# Baseline: In-Process on .NET 8

**Tag:** `baseline-inprocess`

## Initial State

`OrderProcessor` is a classic in-process function app (project SDK `Microsoft.NET.Sdk` with the `Microsoft.NET.Sdk.Functions` package, target framework `net8.0`). An HTTP trigger `POST /api/orders` receives an order as JSON, validates it (`Quantity > 0`, `OrderId` not empty), and writes it to the `orders` queue via an output binding. It is deliberately written in typical in-process style, because exactly these traits cause failures in the cases that follow:

- `static class OrderFunction` with `static Run(...)`
- `ILogger log` as a method parameter
- Output binding as `[Queue("orders")] out string message`
- Synchronous read with `new StreamReader(req.Body).ReadToEnd()`, because a method with an `out` parameter cannot be `async`
- DTO with Newtonsoft attribute: `[JsonProperty("customer_name")]`
- `Newtonsoft.Json` as an explicit package reference

## Prerequisites

It is necessary to set `FUNCTIONS_INPROC_NET8_ENABLED: "1"` in `local.settings.json`. Without this flag, the in-process host that Core Tools 4.13.0 loads for this project is not designed for .NET 8. `func init --worker-runtime dotnet --target-framework net8.0` sets it automatically.

Core Tools 4.13.0 ships two different host binaries and picks the matching one based on the hosting model: one for the in-process environment `Function Runtime Version: 4.851.100.26305` and one for the isolated worker `4.1051.300.26316`. The in-process host is significantly older, which explains both the flag and the package conflict in the next paragraph.

The package version of the Storage extension should be checked. As of the time of writing, the latest version of `Microsoft.Azure.WebJobs.Extensions.Storage.Queues` (5.3.8) pulls in `Microsoft.Extensions.Hosting 10.0.3` and, through it, `Microsoft.Extensions.Options >= 10.0.3` as a transitive dependency. However, the older in-process host only includes the older `Microsoft.Extensions.*` assemblies and cannot load version 10.0.0.0. This results in the following error message when starting:

```
Error configuring services in an external startup class. Microsoft.Azure.WebJobs.Extensions.Storage.Queues: Could not load file or assembly 'Microsoft.Extensions.Options, Version=10.0.0.0, Culture=neutral, PublicKeyToken=adb9793829ddae60'. The system cannot find the file specified.
```

followed by `A host error has occurred during startup operation ...` and `Value cannot be null. (Parameter 'provider')`. Therefore, the repository intentionally pins the version of this extension to 5.3.0, which still works with `Microsoft.Extensions.Hosting 2.1.0` and `Microsoft.Extensions.Options 2.2.0` and is compatible with the bundled host.

After these two adjustments, `dotnet build` runs without errors, and `func start` binds the route `POST http://localhost:7071/api/orders`.

`func start` is the only way to start this state: the project is a library, and `dotnet run` aborts with `The current OutputType is 'Library'.`

## Baseline

This body serves as the baseline for all subsequent cases. Anything the migration changes about it is a contract change, even if nobody reports it. Measured against the in-process host `4.851.100.26305`, `FUNCTIONS_WORKER_RUNTIME=dotnet`, `FUNCTIONS_INPROC_NET8_ENABLED=1`:

```
POST {"OrderId":"ORD-5","customer_name":"Ada","Quantity":1}

HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

{"orderId":"ORD-5","customer_name":"Ada","quantity":1}
```

| Input                         | Result                          |
| ----------------------------- | ------------------------------- |
| valid call                    | 200, body as above              |
| empty `OrderId`, `Quantity` 0 | 400, `Content-Type: text/plain` |
| broken JSON                   | 500                             |

The in-process host serializes `IActionResult` using Newtonsoft and a camelCase naming convention. Therefore, `orderId` and `quantity` were lowercase from the start. Only the attribute-decorated `customer_name` retains its form because `[JsonProperty]` overrides this convention.

This matters for [`serializer-attributes.md`](serializer-attributes.md). The migration doesn't change the naming format as a whole. It changes exactly one field, and two of the three fields stay the same.

`scripts/verify-all.ps1` checks this body exactly, not just the status code. It performs a byte-by-byte comparison of all resolutions of the serialization case (`-fixed-stj`, `-fixed-newtonsoft`, `-fixed-frombody`) against it.

## Sources

- [Develop C# class library functions using Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-dotnet-class-library)
- All statements about `FUNCTIONS_INPROC_NET8_ENABLED` and the package conflict are my own reproduced findings and are not backed by official documentation.