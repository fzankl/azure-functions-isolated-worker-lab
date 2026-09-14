# Logger Parameter: The Host Starts Cleanly

**Tags:** `logger-parameter-broken`, `logger-parameter-fixed`

> **Article reference:** Section "The Logger Is Null, and the Startup Doesn't Reveal It" in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration). This document contains the relevant measurements and sources.

## How This Case Fits In

`logger-parameter-broken` and `sync-read-fixed` have the same code. This error was present from the beginning in the ported code, but it was hidden until now: The `ILogger` parameter is only used after the request body has been read, and this reading was previously terminated with its own HTTP 500 error (see [`sync-read.md`](sync-read.md)). Only with `AllowSynchronousIO` does the execution actually reach the first log line.

## Symptom (`logger-parameter-broken`)

The host reports nothing during startup. For this specific pattern (`ILogger` as a plain method parameter), no indexing error occurs. The host indexes the function and binds the route normally:

```
Functions:
	Order: [POST] http://localhost:7071/api/orders
```

Not until `POST /api/orders` is called with a valid body does it return 500. Literal log excerpt:

```
System.Private.CoreLib: Exception while executing function: Functions.Order. System.Private.CoreLib: Result: Failure
Type: System.ArgumentNullException
Exception: Value cannot be null. (Parameter 'logger')
Stack:    at System.ArgumentNullException.Throw(String paramName)
   at System.ArgumentNullException.ThrowIfNull(Object argument, String paramName)
   at Microsoft.Extensions.Logging.LoggerExtensions.Log(ILogger logger, LogLevel logLevel, EventId eventId, Exception exception, String message, Object[] args)
   at Microsoft.Extensions.Logging.LoggerExtensions.LogInformation(ILogger logger, String message, Object[] args)
   at OrderProcessor.OrderFunction.Run(HttpRequest req, ILogger log) in ...\src\OrderProcessor\OrderFunction.cs
   ...
Executed 'Functions.Order' (Failed, ...)
```

The exception comes from `LoggerExtensions.Log`, i.e., from the use of the logger.

## In the Repository

The diff between `logger-parameter-broken` and `logger-parameter-fixed` is intentionally minimal: `static class` becomes `sealed class` with a constructor, `static Run` becomes `Run`, the `ILogger log` parameter becomes the `_logger` field.

## Result (`logger-parameter-fixed`)

The call returns HTTP 200 again, and the value `Ada` arrives. The field in the response, however, is already called `customerName` instead of `customer_name`, without anyone having changed it. The body is still read with Newtonsoft (`JsonConvert`), which honors `[JsonProperty]`. The response is written by the JSON layer of ASP.NET Core, which ignores it. This is the entry point to [`serializer-attributes.md`](serializer-attributes.md). `scripts/verify-all.ps1` checks exactly these three points: status 200, `"Ada"` present, `customerName` instead of `customer_name`.

## Sources

- [Migrate C# apps from the in-process model to the isolated worker model](https://learn.microsoft.com/en-us/azure/azure-functions/migrate-dotnet-to-isolated-model#logging)
- [Guide for running C# Azure Functions in an isolated worker process](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide#logging)
- How the old parameter fails is not officially documented: The function is still indexed, the parameter remains `null`, and the first log call throws `ArgumentNullException: Value cannot be null. (Parameter 'logger')`. The findings were reproduced in this repository.