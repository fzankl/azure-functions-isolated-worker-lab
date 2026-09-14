# Target State: And Then There's the Version

**Tag:** `target-net10`

> **Article reference:** The DI validation and the `null` configuration binding are described in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration), in the sections "The Logger Is Null, and the Startup Doesn't Reveal It" and "Log Level Changed, Nothing Happens: host.json vs. Worker". This document covers the deadlines, the composition of the tag, the build SDK, and the checks.

## The Two Deadlines

.NET 10 is LTS (Long Term Support), released on November 11, 2025, and supported until November 14, 2028.

.NET 11 is STS (Standard Term Support), will be released on November 10, 2026, and, according to its [release notes](https://github.com/dotnet/core/blob/main/release-notes/11.0/README.md), supported until November 9, 2028, five days shorter than .NET 10. Therefore, those who switch to .NET 11 in November 2026 will shorten their remaining support period.

Independently of this, the in-process model ends on November 10, 2026, coinciding with .NET 8 and .NET 9. In-process supports only .NET 8, so .NET 10 (GA in the isolated worker) requires the migration.

## Composition of This State

`target-net10` raises the target framework to `net10.0` and combines the resolutions of all previous cases:

- Logger parameter: Instance class with `ILogger<OrderFunction>` via constructor.
- Output Binding: Return class with `[QueueOutput]` and `[HttpResult]`.
- Synchronous read: `AllowSynchronousIO` is no longer set; the body is read asynchronously with `ReadFromJsonAsync` (see [`sync-read.md`](sync-read.md)).
- Serialization attributes, variant A: `[JsonPropertyName("customer_name")]` (System.Text.Json).
- Log filter: The `LoggerFilterOptions` rule of the Application Insights provider is removed.

To verify, start Azurite and `dotnet run` (see [`README.md`](../README.md)) and execute the three calls from `http/target-net10.http`: `POST /api/orders` returns 200 with the correctly bound `customer_name`, `GET /api/diagnostics/log-filters` returns the list of rules without the `ApplicationInsightsLoggerProvider` entry, and `GET /api/diagnostics/retry-options` returns the result described below.

## DI Validation at Startup (`ENABLE_BAD_DI_REGISTRATION`)

`src/OrderProcessor/DiValidationExample.cs` has a Singleton (`SingletonConsumer`) consume a Scoped service (`IScopedDependency`). The registration can be enabled via `ENABLE_BAD_DI_REGISTRATION=true`; if the variable is not set, the target state starts normally.

Tested on a copy of the project outside of this repository, using Core Tools 4.13.0, .NET 10.0.400, Worker 2.52.0, and `Azure.Functions.Sdk/1.0.1`.

Under `Development`, the local default of the Core Tools, the startup fails, literally:

```
System.AggregateException: Some services are not able to be constructed (Error while validating the service descriptor 'ServiceType: OrderProcessor.SingletonConsumer Lifetime: Singleton ImplementationType: OrderProcessor.SingletonConsumer': Cannot consume scoped service 'OrderProcessor.IScopedDependency' from singleton 'OrderProcessor.SingletonConsumer'.), ---> System.InvalidOperationException: Error while validating the service descriptor 'ServiceType: OrderProcessor.SingletonConsumer Lifetime: Singleton ImplementationType: OrderProcessor.SingletonConsumer': Cannot consume scoped service 'OrderProcessor.IScopedDependency' from singleton 'OrderProcessor.SingletonConsumer'.
```

With `AZURE_FUNCTIONS_ENVIRONMENT=Production`, the app starts, and the incorrect registration remains undetected.

Enabled via `ConfigureContainer`, the validation also applies under `Production` (not part of the tag): The worker terminates during `Build()` with `dotnet.exe exited with code -532462766 (0xE0434352)` and the same `AggregateException`; the host restarts it multiple times and ends at `Starting worker process failed`. Without the incorrect registration, the same variant starts cleanly with all three functions; `ValidateScopes` therefore does not interfere with the resolution in the worker.

**Not a .NET 10 case:** The automatic validation depends on the 2.x generation of the worker, not the .NET version. It is included here because it was checked in the target state.

## `null` in the Configuration (`RetryOptions`)

`src/OrderProcessor/RetryOptions.cs` sets `MaxRetries` to `3`, `appsettings.json` contains `"Retry": { "MaxRetries": null }`, bound via `builder.Services.Configure<RetryOptions>(builder.Configuration.GetSection("Retry"))`.

`GET /api/diagnostics/retry-options` returns `{"maxRetries":0}`, log line: `Bound RetryOptions.MaxRetries = 0`. Before .NET 10, the same binding failed with an `InvalidOperationException` according to the breaking change page. `3` only remains if `appsettings.json` is not loaded at all: `new HostBuilder()` returns `{"maxRetries":3}`, while `FunctionsApplication.CreateBuilder(args)` and `Host.CreateDefaultBuilder(args)` return `0`. Adding `AddJsonFile("appsettings.json")` to `new HostBuilder()` also returns `0`, so the cause is the builder's default configuration sources, not a missing file.

This is the only case in the repository whose behavior changes with the .NET version and not with the execution model.

## Build SDK and `dotnet run`

All isolated states build with `Azure.Functions.Sdk` 1.0.1. Compared with `Microsoft.Azure.Functions.Worker.Sdk`, the responses from `http/target-net10.http` are byte-identical. The nested `WorkerExtensions` build is gone, and with it the `MSB3030` errors in deep paths (about 110 characters).

`dotnet run` works in every isolated state (supported since `Microsoft.Azure.Functions.Worker.Sdk` 2.0.0) and returns the same responses as `func start`; the SDK sets `OutputType` `Exe` implicitly. Core Tools 4.13.0 warn on `func start` against isolated projects and recommend `dotnet run`. The in-process baseline only runs with `func start`, see [`baseline-inprocess.md`](baseline-inprocess.md).

## Durable Functions

Not part of this repository. Migrating them to the isolated model is a separate, significantly larger topic (its own orchestrator programming model, different triggers and bindings, versioning of running orchestrations).

## Sources

- [.NET and .NET Core official support policy](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)
- [dotnet/core, Release Notes 11.0, section ".NET 11"](https://github.com/dotnet/core/blob/main/release-notes/11.0/README.md): STS, supported from November 10, 2026, to November 9, 2028
- [Supported languages in Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/supported-languages?tabs=isolated-process%2Cv4)
- [Guide for running C# Azure Functions in an isolated worker process](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide), including the section ["Dependency injection"](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide#dependency-injection)
- [Breaking change: Null values preserved in configuration](https://learn.microsoft.com/en-us/dotnet/core/compatibility/extensions/10.0/configuration-null-values-preserved)
