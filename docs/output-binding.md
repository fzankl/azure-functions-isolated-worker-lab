# Output Binding: `out` Is No Longer Available

**Tags:** `output-binding-broken`, `output-binding-fixed`

> **Article reference:** Section "`out` and IBinder Are Gone: The Replacement Has Its Own Pitfalls" in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration). This page documents where the information in the article comes from.

## Compiler Error

Reproducible with `dotnet build`:

```
...\src\OrderProcessor\OrderFunction.cs(14,10): error CS0592: Attribute 'QueueOutput' is not valid on this declaration type. It is only valid on 'method, property, indexer' declarations.
```

The error occurs simply due to the placement of the attribute, regardless of the method's content. With the fix applied, `dotnet build` runs without errors.

The solution implemented on the `output-binding-fixed` tag involves a custom return class: `[QueueOutput]` on a `string` property for the queue, and `[HttpResult]` on an `IActionResult` property for the HTTP response.

`output-binding-fixed` and `sync-read-broken` have the same code. The current version compiles but doesn't run yet because the existing `StreamReader(req.Body).ReadToEnd()` returns a 500 status code on the Kestrel stream (see [`sync-read.md`](sync-read.md)). `scripts/verify-all.ps1` explicitly checks for these two states.

## Four Successful Builds

All four modifications compile with 0 errors and 0 warnings. Three of them fail at runtime, while the fourth is a cross-check. They are measured on top of `logger-parameter-fixed`, the first state that runs. On `output-binding-fixed` itself, every call ends in HTTP 500 before the output binding matters: first because of the synchronous read, and without the ASP.NET Core integration because of the `null` logger. Cases 1 to 3 were tested with the ASP.NET Core integration, case 4 without it.

**1. `[QueueOutput]` directly on the method**  
The HTTP response is correct, but the serialized `OkObjectResult` is placed in the queue instead of the order, even for rejected requests.

**2. A DTO behind `[HttpResult]`**  
The call returns `200` without a body and without `Content-Type`. The queue message is still written. Only the worker log at the `Trace` level reports `No HTTP response returned from function 'Order'`.

**3. Switching to `WorkerOptions.Serializer`**  
The change has no effect, see [`serializer-attributes.md`](serializer-attributes.md). The response is written by the JSON layer of ASP.NET Core, not by the worker pipeline.

**4. Disabling the ASP.NET Core integration**  
Without `ConfigureFunctionsWebApplication()`, there is no Kestrel in the pipeline, and the HTTP 500 error from [`sync-read.md`](sync-read.md) disappears. The same synchronous read operation now returns 200. Verified with `Microsoft.Azure.Functions.Worker.Extensions.Http` 3.3.0 instead of the AspNetCore package. `[HttpResult]` is available there as well. With `FunctionsApplication.CreateBuilder(args)`, the call is simply removed (`ConfigureFunctionsWorkerDefaults()` exists only on `IHostBuilder`). This repository keeps the integration because it matches the in-process signature.

## Sources

- [Guide for running C# Azure Functions in an isolated worker process](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide)
- The exact compiler error message is my own reproduced finding (Roslyn diagnostic `CS0592`), and is not part of the migration guide itself.
- The four findings are my own reproduced measurements.