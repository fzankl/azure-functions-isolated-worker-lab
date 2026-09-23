# HTTP 200, and the Data Is Gone: A Runnable Azure Functions Migration Sample

A small Azure Functions app that reproduces, one git tag at a time, every failure that shows up when you migrate a C# function app from the **in-process model** to the **isolated worker model**. Including the silent ones: 200 OK, empty field, no error log.

**Language.** This page is English: setup, every tag, every measured response, and the serialization case in full. The other cases are written up in `docs/`, also in English. [`README.de.md`](README.de.md) is the short German companion for the talk this repository also was built for.

Everything runs locally. No Azure subscription, no network access at runtime.

The write-up behind this repository: [After the migration: What to do once your Function App is up and running again](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration).

## The Case Most People Arrive Here For

After migrating, a DTO property annotated with Newtonsoft's `[JsonProperty]` binds to `null`, and nothing reports a problem.

```csharp
public class OrderRequest
{
    public string? OrderId { get; set; }

    [JsonProperty("customer_name")] // Newtonsoft, carried over from the in-process app
    public string? CustomerName { get; set; }

    public int Quantity { get; set; }
}
```

Same request (`{"OrderId":"ORD-5","customer_name":"Ada","Quantity":1}`), measured against a running host:

| State                                                        | Response body                                                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| in-process (before the migration)                            | `{"orderId":"ORD-5","customer_name":"Ada","quantity":1}`                              |
| isolated + ASP.NET Core integration                          | `{"orderId":"ORD-5","customerName":null,"quantity":1}`                                |
| `WorkerOptions.Serializer = NewtonsoftJsonObjectSerializer`  | `{"orderId":"ORD-5","customerName":null,"quantity":1}` (setting has no effect)        |
| `AddControllers().AddNewtonsoftJson()` + `ReadFromJsonAsync` | `{"orderId":"ORD-5","customer_name":null,"quantity":1}` (name back, value still gone) |
| any of the three resolutions below                           | identical to the in-process row                                                       |

Two of three fields are unchanged. There is no wholesale format switch to notice: one field has a different name and no value.

The in-process host serializes `IActionResult` with Newtonsoft and a **camelCase** naming policy. `orderId` and `quantity` were always lowercase. Only the annotated `customer_name` keeps its shape. Adding a `DefaultContractResolver` to "restore PascalCase" moves you *away* from the old contract, not toward it.

### The Documented Fix Depends on the Input Path

Same DTO, same request. Whether `CustomerName` binds:

| Input path                                                  | default | `WorkerOptions.Serializer` | `AddControllers().AddNewtonsoftJson()` |
| ----------------------------------------------------------- | ------- | -------------------------- | -------------------------------------- |
| `await req.ReadFromJsonAsync<T>()`                          | `null`  | `null`                     | `null`                                 |
| `[FromBody] T` from `Microsoft.Azure.Functions.Worker.Http` | `null`  | `null`                     | **`"Ada"`**                            |
| `[FromBody] T` from `Microsoft.AspNetCore.Mvc`              | `null`  | `null`                     | `null`                                 |

`AddNewtonsoftJson()` switches the **MVC formatter layer**. The worker's `[FromBody]` takes its deserialization from that layer, so the switch reaches it. `ReadFromJsonAsync` is the `Microsoft.AspNetCore.Http.Json` extension, hard-wired to System.Text.Json. Its options type exposes a single `JsonSerializerOptions` property, so there is no seam to plug Newtonsoft into.

This is why [azure-functions-dotnet-worker#2131](https://github.com/Azure/azure-functions-dotnet-worker/issues/2131) is both correct and unhelpful if you arrive with `ReadFromJsonAsync`: the answer there assumes `[FromBody]`, and nothing says so.

The same gap is in the official guide. [Its JSON section](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide#json-serialization-with-aspnet-core-integration) does tell you that general worker serialization config has no effect under the integration, and it does name `.AddMvc()` as the switch, so this is *not* an undocumented behavior. What it never states is the scope: it says "the serialization behavior used for your HTTP triggers", which reads as both directions, and the words `ReadFromJsonAsync` and `FromBody` appear nowhere on the page. You get the right switch with no way to tell why it did not help.

The migration guide had the same blind spot: nothing there said that Newtonsoft attributes stop working. [MicrosoftDocs/azure-docs#128734](https://github.com/MicrosoftDocs/azure-docs/pull/128734) (merged) adds that note.

### The Three Resolutions

All three produce a body byte-identical to the in-process one.

**A: move the DTO to System.Text.Json**  
*Tag:* `serializer-attributes-fixed-stj`  

Simplest if you own the DTO. The `Newtonsoft.Json` package reference disappears entirely.

```csharp
[JsonPropertyName("customer_name")]
```

**B: Newtonsoft in both layers, reading by hand**  
*Tag:* `serializer-attributes-fixed-newtonsoft`

```csharp
builder.Services.AddControllers().AddNewtonsoftJson();           // response
string body = await new StreamReader(req.Body).ReadToEndAsync(); // request
var order = JsonConvert.DeserializeObject<OrderRequest>(body);
```

Use `ReadToEndAsync()`, not `ReadToEnd()`: Kestrel is in the pipeline and rejects synchronous reads. This variant needs **no** `AllowSynchronousIO` as long as the read is async.

**C: `[FromBody]`, the smallest migration diff**  
*Tag:* `serializer-attributes-fixed-frombody`  

For a real migration this is the first choice: the DTO is untouched, there is no manual read, and `AllowSynchronousIO` never enters the picture.

```csharp
builder.Services.AddControllers().AddNewtonsoftJson(); // no ContractResolver

public OrderFunctionResult Run(
    [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req,
    [Microsoft.Azure.Functions.Worker.Http.FromBody] OrderRequest order)
```

Three things belong with that recommendation:

- **Fully qualify the attribute**  
  With `using Microsoft.AspNetCore.Mvc;` in the file (and it is there, for `IActionResult`), a bare `[FromBody]` is ambiguous (`error CS0104`). If only the MVC namespace is visible, it compiles without a warning and does not bind.
- **No `ContractResolver`**  
  `DefaultContractResolver` yields `{"OrderId":...,"Quantity":...}` and breaks the match with the in-process contract.
- **Coverage is uneven**  
  `AddNewtonsoftJson()` is global for responses. `[FromBody]` applies only where you write it. A function you forget keeps reading with System.Text.Json, silently. Grep for `ReadFromJsonAsync` and `StreamReader(req.Body)`.

C keeps you on Newtonsoft. The move to System.Text.Json belongs afterwards, as its own, separately tested step.

### It Is Not Only `[JsonProperty]`

Every serialization attribute on the DTO is affected, and `[JsonIgnore]` fails in the more unpleasant direction: each layer honors its own and ignores the other's. With System.Text.Json writing, a property marked `[Newtonsoft.Json.JsonIgnore]` is emitted. With Newtonsoft writing, a `[System.Text.Json.Serialization.JsonIgnore]` one is. "Field missing" becomes "field suddenly present."

## Running It

Prerequisites: .NET SDK 8 (and 10 for the final tag), Azure Functions Core Tools 4.x, Docker (for Azurite), git.

The isolated-worker tags build through the [`Azure.Functions.Sdk`](https://www.nuget.org/packages/Azure.Functions.Sdk/) MSBuild SDK 1.0.1, which replaces the former `PackageReference` on `Microsoft.Azure.Functions.Worker.Sdk`. It is restored from nuget.org on first build, so there is nothing to install up front. The `baseline-inprocess` tag is unaffected and still builds with the project SDK `Microsoft.NET.Sdk` and the `Microsoft.NET.Sdk.Functions` package.

```bash
docker run -d --name azurite-demo -p 10000:10000 -p 10001:10001 -p 10002:10002 \
  mcr.microsoft.com/azure-storage/azurite

git checkout serializer-attributes-broken
cd src/OrderProcessor
dotnet build # fails on purpose only at output-binding-broken
dotnet run
```

`dotnet run` is the way in for every isolated-worker tag. The one exception is `baseline-inprocess`: that project is a library, and `dotnet run` refuses it. Start that tag with `func start`.

```bash
curl -X POST http://localhost:7071/api/orders \
  -H "Content-Type: application/json" \
  -d '{"OrderId":"ORD-5","customer_name":"Ada","Quantity":1}'
```

Every locally runnable case has its own `.http` file under `http/`, usable with the VS Code REST Client extension.

**`docs/` lives on `main` only** and is in no tag. Check out a tag and you get the code, `http/` and a short README that points back to `main`, plus `aspire/` at the closing tag, but no `docs/` directory.

## Tags

`git tag --sort=creatordate` lists them in migration order. The numbers below are the same in [`README.de.md`](README.de.md) and in the talk.

| #   | Case                                                  | Tag                                      | What it shows                                                                                                                                                                          |
| --- | ----------------------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Starting point: in-process on .NET 8                  | `baseline-inprocess`                     | Working in-process starting point, `HttpRequest` in, `IActionResult` out, no failure yet                                                                                               |
| 2   | Output binding: `out` is gone                         | `output-binding-broken`                  | Output binding as an `out` parameter: compile error `CS0592`                                                                                                                           |
| 3   | ↳ Resolution                                          | `output-binding-fixed`                   | Return class with `[QueueOutput]` and `[HttpResult]`. Compiles, does not run yet                                                                                                       |
| 4   | Synchronous read: the line that worked for years      | `sync-read-broken`                       | `StreamReader(req.Body).ReadToEnd()` on the Kestrel stream: 500, `Synchronous operations are disallowed`                                                                               |
| 5   | ↳ Resolution                                          | `sync-read-fixed`                        | `AllowSynchronousIO = true`. That 500 is gone, the next one is immediate                                                                                                               |
| 6   | Logger parameter: the host starts cleanly             | `logger-parameter-broken`                | `ILogger` as a bare parameter: route is indexed, every call throws `ArgumentNullException`                                                                                             |
| 7   | ↳ Resolution                                          | `logger-parameter-fixed`                 | Instance class with constructor injection. 200, value correct, field name already `customerName`                                                                                       |
| 8   | Serialization attributes: 200, and the field is empty | `serializer-attributes-broken`           | The clean fix for the 500 (`ReadFromJsonAsync`) creates the silent failure                                                                                                             |
| 9   | ↳ The fix you find everywhere                         | `serializer-attributes-worker-noop`      | `WorkerOptions.Serializer` set to Newtonsoft: no effect, no message                                                                                                                    |
| 10  | ↳ Resolution A                                        | `serializer-attributes-fixed-stj`        | `[JsonPropertyName]`                                                                                                                                                                   |
| 11  | ↳ Resolution B                                        | `serializer-attributes-fixed-newtonsoft` | `AddControllers().AddNewtonsoftJson()` plus an explicit Newtonsoft read                                                                                                                |
| 11a | ↳ Resolution C *(off the demo path)*                  | `serializer-attributes-fixed-frombody`   | Smallest migration diff. Sits as a branch off tag 11, not in the linear chain, and therefore sorts last by creation date                                                               |
| 12  | Log filter: the logs are gone                         | `log-filter-broken`                      | Application Insights default filter swallows `LogInformation`, diagnosed through a local endpoint instead of an Azure query                                                            |
| 13  | ↳ Resolution                                          | `log-filter-fixed`                       | Filter rule removed                                                                                                                                                                    |
| 14  | Slot swap: green swap, dead in production             | *(no tag)*                               | Staging slot swap in Azure, both failure modes played through, see [`docs/slot-swap.md`](docs/slot-swap.md)                                                                            |
| 15  | Target state: and then there is the version           | `target-net10`                           | .NET 10, isolated, all resolutions applied, plus two extra examples: startup DI validation (worker 2.x, not .NET 10 specific) and `null` out of configuration binding                  |
| 16  | Closing picture (optional)                            | `aspire-optional`                        | Optional .NET Aspire stage, see [`docs/aspire.md`](docs/aspire.md)                                                                                                                     |

Case 14 has no tag and does not run locally. It needs a real Azure environment with two slots.

The tags are annotated and were created in the order of the table, so `--sort=creatordate` matches it, with one exception: `serializer-attributes-fixed-frombody` (11a) was created later and appears last. In the commit history it is not part of the chain either, but a branch off `serializer-attributes-fixed-newtonsoft`.

From `log-filter-broken` on, the code continues with resolution A, not B: tag 12 follows tag 11 in the history, but reads with `ReadFromJsonAsync` again, uses `[JsonPropertyName]` and drops both Newtonsoft packages. `target-net10` keeps that state.

## Versions

Measured on Windows 11 with Core Tools 4.13.0 and .NET SDK 8.0.419 and 10.0.400.

Isolated worker tags (`net8.0`, `net10.0` from `target-net10` on), host runtime `4.1051.300.26316`. The first four are in every isolated tag, the rest only where the case needs them:

| Package                                                       | Version | In                                                                                                          |
| ------------------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------- |
| `Azure.Functions.Sdk` (MSBuild SDK)                           | 1.0.1   | all                                                                                                         |
| `Microsoft.Azure.Functions.Worker`                            | 2.52.0  | all                                                                                                         |
| `Microsoft.Azure.Functions.Worker.Extensions.Http.AspNetCore` | 2.1.1   | all                                                                                                         |
| `Microsoft.Azure.Functions.Worker.Extensions.Storage.Queues`  | 5.5.5   | all                                                                                                         |
| `Newtonsoft.Json`                                             | 13.0.4  | up to `-worker-noop`, plus `-fixed-newtonsoft` and `-fixed-frombody`, not in `-fixed-stj` or later tags     |
| `Microsoft.Azure.Core.NewtonsoftJson`                         | 2.0.0   | `serializer-attributes-worker-noop` only, to demonstrate the ineffective fix                                |
| `Microsoft.AspNetCore.Mvc.NewtonsoftJson`                     | 8.0.25  | `-fixed-newtonsoft` and `-fixed-frombody`, matching the locally installed `Microsoft.AspNetCore.App` 8.0.25 |
| `Microsoft.Azure.Functions.Worker.ApplicationInsights`        | 2.51.0  | `log-filter-*`, `target-net10` and `aspire-optional`                                                        |
| `Microsoft.ApplicationInsights.WorkerService`                 | 2.23.0  | `log-filter-*`, `target-net10` and `aspire-optional`                                                        |

In-process baseline (`net8.0`), project SDK `Microsoft.NET.Sdk` (the Functions build logic comes from the `Microsoft.NET.Sdk.Functions` package), host runtime `4.851.100.26305`, `FUNCTIONS_INPROC_NET8_ENABLED=1`:

| Package                                             | Version |
| --------------------------------------------------- | ------- |
| `Microsoft.NET.Sdk.Functions`                       | 4.6.0   |
| `Microsoft.Azure.WebJobs.Extensions.Storage.Queues` | 5.3.0   |
| `Newtonsoft.Json`                                   | 13.0.4  |

`Storage.Queues` is deliberately pinned to 5.3.0 on the in-process side: newer versions pull `Microsoft.Extensions.*` 10.x, which the bundled in-process host cannot load.

## Documentation

`docs/` carries the evidence per case: verbatim error messages, measured responses, counter-tests, and sources. The explanation is in the article linked at the top, and each document names the section that covers it. `slot-swap.md` and `baseline-inprocess.md` are the two the article does not touch.

- [`docs/slot-swap.md`](docs/slot-swap.md): the case with no tag, played through in a real Azure environment.
- [`docs/log-filter.md`](docs/log-filter.md): the swallowed logs, measured on the classic and the OpenTelemetry path.
- [`docs/sync-read.md`](docs/sync-read.md): the 500 on the synchronous read, including where the Microsoft documentation is too narrow (fixed via [MicrosoftDocs/azure-docs#128726](https://github.com/MicrosoftDocs/azure-docs/pull/128726)).
- Appendix in [`docs/output-binding.md`](docs/output-binding.md): four cleanup ideas that compile and change behavior silently.
- [`docs/serializer-attributes.md`](docs/serializer-attributes.md): the measurement series behind the case above, every tag, three cross-checks.
- [`docs/baseline-inprocess.md`](docs/baseline-inprocess.md), [`docs/logger-parameter.md`](docs/logger-parameter.md), [`docs/target-net10.md`](docs/target-net10.md), [`docs/aspire.md`](docs/aspire.md): one chapter per case.

## Verification Script

`scripts/verify-all.ps1` builds every locally runnable tag except `aspire-optional` in its own git worktree, starts the runnable ones and asserts the responses documented in `docs/`, including a byte-exact comparison of all three resolutions against the recorded in-process body. A failing tag does not stop the run. The script checks all tags and exits non-zero if any check failed. Pass tag names to check a subset:

```powershell
.\scripts\verify-all.ps1 baseline-inprocess serializer-attributes-fixed-frombody
```

It is meant as evidence, not as a general-purpose tool. It assumes Windows with PowerShell, a running Docker Desktop, plus `func` and the SDKs from the prerequisites above.

## Scope

No database, no authentication, no other triggers. Every additional line would have distracted in the demo. Durable Functions are not touched, see [`docs/target-net10.md`](docs/target-net10.md). Aspire is deliberately off the main path, reasoning in [`docs/aspire.md`](docs/aspire.md).

## License

The code (`src/`, `aspire/`, `http/`, `scripts/` and the configuration files) is licensed under the [MIT License](LICENSE). The documentation (`docs/` and the READMEs) is licensed under [CC BY 4.0](LICENSE-docs). Both © 2026 Fabian Zankl.
