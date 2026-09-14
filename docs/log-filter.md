# Log Filter: The Logs Are Gone

**Tags:** `log-filter-broken`, `log-filter-fixed`

> **Article reference:** Section "Missing LogInformation: Two Log Sources and One Filter Rule" in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration). This document shows where the information in the article comes from.

## Why a Diagnostic Endpoint

In practice, it takes minutes for telemetry to arrive in Application Insights and be indexed. That rules it out for a quick cross-check, and this repository runs without an Azure subscription. Instead, the endpoint `GET /api/diagnostics/log-filters` (`src/OrderProcessor/DiagnosticsFunction.cs`) iterates through the registered `LoggerFilterOptions.Rules` in the DI container and writes the provider, category, and minimum level to both the console and the HTTP response.

## Existing Rules (`log-filter-broken`)

Reproducible with `dotnet run`, without any Azure connection:

```
LoggerFilterOptions.Rules (5 total):
Provider=Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider Category=(any) MinLevel=Warning
Provider=Microsoft.Extensions.Logging.EventLog.EventLogLoggerProvider Category=(any) MinLevel=(unset)
Provider=(any) Category=Microsoft.Hosting.Lifetime MinLevel=None
Provider=Microsoft.Extensions.Logging.EventLog.EventLogLoggerProvider Category=(any) MinLevel=(unset)
Provider=(any) Category=Microsoft.Hosting.Lifetime MinLevel=None
```

The console output still shows `LogInformation` text, such as the lines from the diagnostic function itself. The console provider is not affected by the rule.

## Origin of Duplicates

The duplicates (`EventLogLoggerProvider` and `Microsoft.Hosting.Lifetime`) are created in `FunctionsApplication.CreateBuilder(args)`. This was verified by outputting the rules after each setup stage: 4 rules after `CreateBuilder`, still 4 after `ConfigureFunctionsWebApplication()`, and 5 after the Application Insights registration. The duplicates do not affect the filter result. Identical rules lead to the same selection as a single rule.

## Resolution

### Classic: Remove the Rule (`log-filter-fixed`)

The same call against `log-filter-fixed` returns the same rule list without the `ApplicationInsightsLoggerProvider` entry.

Difference from the article: The tagged version filters only on `ProviderName`, while the article shows the narrower version that also checks `CategoryName is null` and `LogLevel == LogLevel.Warning`. In the demo project, there is no separate rule for the same provider, so both versions produce the same result here.

### OpenTelemetry: The Rule Is Not Created

The OpenTelemetry path does not create the rule at all. This was verified with a second variant of `log-filter-broken`, where the classic registration, including the packages `Microsoft.Azure.Functions.Worker.ApplicationInsights` and `Microsoft.ApplicationInsights.WorkerService`, is removed. Instead, `AddOpenTelemetry().UseFunctionsWorkerDefaults().UseAzureMonitorExporter()` with `Microsoft.Azure.Functions.Worker.OpenTelemetry` 1.2.0, `Azure.Monitor.OpenTelemetry.Exporter` 1.8.3, and `OpenTelemetry.Extensions.Hosting` 1.17.0 is used. The same call returns four rules instead of five:

```json
[{"providerName":"Microsoft.Extensions.Logging.EventLog.EventLogLoggerProvider","categoryName":null,"logLevel":null},{"providerName":null,"categoryName":"Microsoft.Hosting.Lifetime","logLevel":"None"},{"providerName":"Microsoft.Extensions.Logging.EventLog.EventLogLoggerProvider","categoryName":null,"logLevel":null},{"providerName":null,"categoryName":"Microsoft.Hosting.Lifetime","logLevel":"None"}]
```

Only the four default rules that `CreateBuilder` already sets remain.

Additional finding from the same run: `UseAzureMonitorExporter()` refuses to start without a connection string. The worker terminates with `System.InvalidOperationException: A connection string was not found. Please set your connection string.`, and the host reports `A host error has occurred during startup operation`. A dummy connection string was therefore set for the measurement.

## Sources

- [Guide for running C# Azure Functions in an isolated worker process](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide)
- The rule content (`ApplicationInsightsLoggerProvider` on `Warning`) and the resolution via `LoggerFilterOptions` were documented in the guide until April 2026 ([last version](https://github.com/MicrosoftDocs/azure-docs/blob/b4442d6f4f5d63838330989b82f38825bc7a477c/articles/azure-functions/dotnet-isolated-process-guide.md#managing-log-levels)). With the transition to OpenTelemetry, both were removed ([Commit 5c635c3](https://github.com/MicrosoftDocs/azure-docs/commit/5c635c3cf9519c792d46922b1b6a94d4e122aca3)).