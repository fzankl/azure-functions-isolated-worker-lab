# Slot Swap: Green Swap, Dead in Production

**Tag:** *(none, this case does not run locally)*

This case requires a real Azure environment with two slots. The initial state is as described in `baseline-inprocess`. The exceptions originate from the connected Application Insights.

## Procedure

1. Create a Staging slot.
2. In the Staging slot, set `FUNCTIONS_WORKER_RUNTIME` to `dotnet-isolated`, but do not mark it as a slot setting.
3. Deploy the migrated code to the Staging slot.
4. Test the Staging environment. Errors in the logs during the switch are expected, according to the documentation.
5. Swap the Staging slot to Production.
6. Test the Production environment.

## Error Scenario 1: Only Half of the Configuration Changed

If the setting in the Staging slot does not match the deployed code, the platform reports the diagnostic event **AZFD0013**. The setting and the code must match within the same slot before the swap.

Observed with two wordings. Immediately after setting the configuration, without a new deployment:

> The 'FUNCTIONS_WORKER_RUNTIME' is set to 'dotnet-isolated', which does not match the worker runtime metadata found in the deployed function app artifacts. The deployed artifacts are for 'CSharp'. See https://aka.ms/functions-invalid-worker-runtime for more information. The application will continue to run, but may throw an exception in the future.

After deploying the migrated code, the same sentence ends with `for 'dotnet'`. `CSharp` is the `language` value from `function.json`, and `dotnet` is the in-process value from `FUNCTIONS_WORKER_RUNTIME`. If you are looking for a specific term, you will only find part of the messages.

Once the setting and the code match, the event stops. However, the line remains in the portal notifications with a count of occurrences. The "Last Occurred" column indicates whether the finding is current. This column is the release criterion before a swap, not the line itself.

## Error Scenario 2: The Setting Is Marked as a Slot Setting

A slot setting remains in the slot during the swap. The isolated code moves to Production, `FUNCTIONS_WORKER_RUNTIME=dotnet-isolated` remains in Staging, and Production retains `dotnet`. `netFrameworkVersion` and the 32/64-bit setting are *General Settings* and always move with the swap. Only App Settings are affected. This was tested with a swap and a swap back.

### Initial State

`FUNCTIONS_WORKER_RUNTIME` was marked as a slot setting in both slots. Both slots returned HTTP 200 with `{"orderId":"ORD-1","customer_name":"Ada","quantity":2}`.

|                                 | Production                                 | Staging                                             |
| ------------------------------- | ------------------------------------------ | --------------------------------------------------- |
| Content                         | In-process (`bin/`, `Order/function.json`) | Isolated (`worker.config.json`, `.azurefunctions/`) |
| `FUNCTIONS_WORKER_RUNTIME`      | `dotnet` · sticky                          | `dotnet-isolated` · sticky                          |
| `FUNCTIONS_INPROC_NET8_ENABLED` | `1` · moves with                           | —                                                   |
| `WEBSITE_RUN_FROM_PACKAGE`      | —                                          | `1` · moves with                                    |
| `netFrameworkVersion`           | `v8.0` · moves with                        | `v10.0` · moves with                                |

### After the Swap

```
PS> az functionapp deployment slot swap -g <rg> -n <app> --slot staging --target-slot production
exit code: 0
```

77 seconds, no output lines. Then:

|                                    | Production | Staging  |
| ---------------------------------- | ---------- | -------- |
| `POST /api/orders`                 | HTTP 503   | HTTP 200 |
| `GET /api/diagnostics/log-filters` | HTTP 503   | HTTP 404 |

All settings except `FUNCTIONS_WORKER_RUNTIME` moved with the content. That Production goes down as a result is to be expected. Notably, the swap still reported success. The 404 in Staging confirms the swap: `DiagnosticsFunction` only exists in the migrated code.

### What the Host Does

The event log (`LogFiles/eventlog.xml`) of the site that was the Staging slot before the swap. The swap ran from 18:09:21 to 18:10:38:

```
18:08:44  SiteExtensions\Functions\4.1053.200        started   (staging, dotnet-isolated)
18:09:25  <app>                                      shutdown  (swap)
18:09:37  SiteExtensions\FunctionsInProc\4.641.300   started   (with production settings, dotnet)
```

During the swap, the site receives the Production slot settings and restarts. The platform chooses the host based on `FUNCTIONS_WORKER_RUNTIME`, so it loads the in-process host for isolated content. Because `FUNCTIONS_INPROC_NET8_ENABLED` was not sticky and is in Staging, it's `FunctionsInProc` instead of `FunctionsInProc8`, which Production previously loaded.

The host reads the `extensions.json` of the isolated package and repeatedly fails every five to twenty seconds. From Application Insights:

```
Microsoft.Azure.WebJobs.Script.ExternalStartupException
    Error configuring services in an external startup class.
 ---> System.IO.FileNotFoundException
    Could not load file or assembly 'System.ComponentModel, Version=8.0.0.0, ...'.

  Assembly: Microsoft.Azure.WebJobs.Extensions.Storage.Queues, Version=5.3.8.0
```

Version 5.3.8 comes from the isolated package, while the in-process version is pinned to 5.3.0 (see [`baseline-inprocess.md`](baseline-inprocess.md)). The restart loop explains the 503 error.

The exception does not mention `FUNCTIONS_WORKER_RUNTIME`, a slot, or a swap. This directs suspicion towards corrupted packages or build errors, which is the wrong direction. Under `LogFiles/Application/Functions/Host/`, no new file was created; the host doesn't get far enough. Without Application Insights, the issue is not diagnosable from within.

### The Mismatch Is Not Symmetrical

| Artifacts  | `FUNCTIONS_WORKER_RUNTIME` | Result                |
| ---------- | -------------------------- | --------------------- |
| Isolated   | `dotnet`                   | HTTP 503, App down    |
| In-process | `dotnet-isolated`          | HTTP 200, App running |

Both directions occurred during the same swap. AZFD0013 promises "The application will continue to run," which is only true for the second row. The dangerous direction is the one being migrated to.

### Swap Back

A second swap restores the original state, after which both slots again return HTTP 200. The damage is reversible if noticed.

## Side Findings

### ZipDeploy Doesn't Clean Up

`az functionapp deployment source config-zip` does not delete files that are missing from the package. The in-process package over isolated artifacts resulted in a mixed state: `bin/` and `Order/` alongside `worker.config.json` and `.azurefunctions/`. Such a mixed state in the opposite direction could also explain the vocabulary change in AZFD0013. To ensure a clean result, use:

```
az webapp deploy -g <rg> -n <app> --src-path <zip> --type zip --clean true --restart true
```

### An Empty wwwroot Goes Unnoticed

In the Staging slot, the migrated code was already deployed without a package. Then `WEBSITE_RUN_FROM_PACKAGE=1` was added, and the next publish from Visual Studio failed. As a result, the setting was in place, but no ZIP package existed. The previously deployed files were no longer visible; wwwroot only contained `FAILED TO INITIALIZE RUN FROM PACKAGE.txt` and `web.config`. No worker started, and requests timed out. The portal reported nothing about this; the information is only in the filename.

## Verification Methods

- **Status Code**  
  `GET /api/diagnostics/log-filters` only exists in the migrated code. 200 means migrated code, 404 means in-process content, 503 means a host that starts and fails, and timeout means there is nothing to load.
- **Content**  
  Kudu VFS API under `/api/vfs/site/wwwroot/`, with Entra ID token (Basic Auth was disabled). `worker.config.json` and `.azurefunctions/` indicate isolated, `bin/` with `function.json` indicates in-process, and both together indicate an unclean deployment.
- **Event Log**  
  `/api/vfs/LogFiles/eventlog.xml`, XML fragment, timestamps in UTC (the excerpt above shows them converted to local time).
- **Exceptions**  
  Application Insights, connected to both slots. `az monitor app-insights query` expects the resource name under `--app` with `-g`; map columns via `tables[0].columns[].name`.

## Sources

- [Migrate C# apps from the in-process model to the isolated worker model](https://learn.microsoft.com/en-us/azure/azure-functions/migrate-dotnet-to-isolated-model)
- Diagnostic event `AZFD0013`: [The configured runtime does not match the worker runtime metadata found in the deployed function app artifacts](https://learn.microsoft.com/en-us/azure/azure-functions/errors-diagnostics/diagnostic-events/azfd0013)
- [Set up staging environments in Azure App Service](https://learn.microsoft.com/en-us/azure/app-service/deploy-staging-slots)
- AZFD0013 in both wordings, swap and swap back, the empty wwwroot, and the mixed state after `config-zip` are my own measurements made in a Function App with a staging slot.
