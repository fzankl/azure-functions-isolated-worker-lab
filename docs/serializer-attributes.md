# Serialization Attributes: 200, and the Field Is Empty

**Tags:** `serializer-attributes-broken`, `serializer-attributes-worker-noop`, `serializer-attributes-fixed-stj`, `serializer-attributes-fixed-newtonsoft`, `serializer-attributes-fixed-frombody`

> **Article reference:** Section "Status Code 200 and a Field That Remains Null" in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration). This page documents where the information in the article comes from.

## Symptoms and Resolutions

Reproducible with `dotnet run` against the isolated host `4.1051.300.26316`, comparison values against the in-process host `4.851.100.26305`, invocation `POST /api/orders` with `{"OrderId":"ORD-5","customer_name":"Ada","Quantity":1}`:

| Tag                                      | Body                                                     | Log Line                           |
| ---------------------------------------- | -------------------------------------------------------- | ---------------------------------- |
| *(in-process baseline)*                  | `{"orderId":"ORD-5","customer_name":"Ada","quantity":1}` | `Order ORD-5 for Ada accepted.`    |
| `serializer-attributes-broken`           | `{"orderId":"ORD-5","customerName":null,"quantity":1}`   | `Order ORD-5 for (null) accepted.` |
| `serializer-attributes-worker-noop`      | unchanged compared to `-broken`                          | unchanged                          |
| `serializer-attributes-fixed-stj`        | identical to baseline, byte-for-byte                     | `Order ORD-5 for Ada accepted.`    |
| `serializer-attributes-fixed-newtonsoft` | identical to baseline, byte-for-byte                     | `Order ORD-5 for Ada accepted.`    |
| `serializer-attributes-fixed-frombody`   | identical to baseline, byte-for-byte                     | `Order ORD-5 for Ada accepted.`    |

No tag reports an exception or writes an error log. For `-broken`, the message in the queue `orders` also does not contain `customer_name`.

These measurements led to [MicrosoftDocs/azure-docs#128734](https://github.com/MicrosoftDocs/azure-docs/pull/128734) (merged).

The three resolutions are named as follows: Variant A (`-fixed-stj`, `[JsonPropertyName]` from System.Text.Json), Variant B (`-fixed-newtonsoft`, `AddNewtonsoftJson()` plus an explicit read operation with `JsonConvert`), and Variant C (`-fixed-frombody`, `AddNewtonsoftJson()` plus `[FromBody]` from the worker namespace).

In Variant C, as in the baseline, a rule violation (empty `OrderId` or `Quantity` 0) results in an HTTP 400 error, while invalid JSON results in an HTTP 500 error.

The demo path runs through Variant B, because the explicit read operation makes it clear that input and output are two separate layers. Variant C has its own tag off the demo path, `serializer-attributes-fixed-frombody`; under `serializer-attributes-fixed-newtonsoft`, `src/OrderProcessor/OrderFunction.cs` additionally contains it as a commented-out block with justification. From `log-filter-broken` on, the code continues with Variant A, and [`target-net10.md`](target-net10.md) keeps it. `Microsoft.Azure.Core.NewtonsoftJson` only exists in the `-worker-noop` tag within the project.

`serializer-attributes-fixed-frombody` branches off `serializer-attributes-fixed-newtonsoft` and is not in the linear tag sequence. `scripts/verify-all.ps1` checks it as well, see [`baseline-inprocess.md`](baseline-inprocess.md).

## Three Input Paths

Each cell is a separate build with the same DTO (`[JsonProperty("customer_name")]`) and the same invocation. All builds run with 0 errors and 0 warnings. The table shows whether `CustomerName` is bound:

| Input Path                                                | Default | `WorkerOptions.Serializer` | `AddControllers().AddNewtonsoftJson()` |
| --------------------------------------------------------- | ------- | -------------------------- | -------------------------------------- |
| `await req.ReadFromJsonAsync<T>()`                        | `null`  | `null`                     | `null`                                 |
| `[FromBody]` from `Microsoft.Azure.Functions.Worker.Http` | `null`  | `null`                     | **`"Ada"`**                            |
| `[FromBody]` from `Microsoft.AspNetCore.Mvc`              | `null`  | `null`                     | `null`                                 |

Variant C, and therefore the tag `serializer-attributes-fixed-frombody`, follows from this table: `[FromBody]` from the worker namespace is the only input path that `AddNewtonsoftJson()` also fixes. `[FromBody]` from `Microsoft.AspNetCore.Mvc` compiles without warnings and does not bind. If both namespaces are visible, the compiler reports `error CS0104`.

The middle row confirms the maintainer's statement from issue #2131: `[FromBody]` from the worker namespace remains `null` even when `WorkerOptions.Serializer` is set.

## Three Cross-Checks

**1. Explicit read operation in Variant B**  
The starting point is `serializer-attributes-fixed-newtonsoft`. Only the explicit read operation is replaced by `await req.ReadFromJsonAsync<OrderRequest>()`. The build runs with 0 errors and 0 warnings, but the value is lost at runtime:

```
200 {"orderId":"ORD-5","customer_name":null,"quantity":1}
Order ORD-5 for (null) accepted.
```

**2. `[JsonIgnore]` in both directions**  
DTO with both ignore attributes, otherwise unchanged compared to `serializer-attributes-broken`:

```csharp
[Newtonsoft.Json.JsonIgnore]                public string? SecretNewtonsoftIgnored { get; set; }
[System.Text.Json.Serialization.JsonIgnore] public string? SecretStjIgnored { get; set; }
```

Output, same application, only the writing layer is changed:

| Serializer                         | Body                                                                                         |
| ---------------------------------- | -------------------------------------------------------------------------------------------- |
| System.Text.Json (Default)         | `{"orderId":"ORD-9","customerName":"Ada","quantity":1,"secretNewtonsoftIgnored":"LEAK-NSJ"}` |
| Newtonsoft (`AddNewtonsoftJson()`) | `{"orderId":"ORD-9","customer_name":"Ada","quantity":1,"secretStjIgnored":"LEAK-STJ"}`       |

Input, same run:

```
Request:  {"secretNewtonsoftIgnored":"FROM-CLIENT-NSJ","secretStjIgnored":"FROM-CLIENT-STJ"}
Bound:    SecretNewtonsoftIgnored = "FROM-CLIENT-NSJ", SecretStjIgnored = null
```

Identical in both runs because `ReadFromJsonAsync` is not affected by `AddNewtonsoftJson()`.

**3. Without ASP.NET Core Integration**  
`Microsoft.Azure.Functions.Worker.Extensions.Http` 3.3.0 instead of the AspNetCore version, `FunctionsApplication.CreateBuilder(args)` without `ConfigureFunctionsWebApplication()`, input via `HttpRequestData.ReadFromJsonAsync<T>()`, output via `WriteAsJsonAsync`. First run with the default serializer:

```
POST {"OrderId":"ORD-2","customer_name":"Grace","Quantity":3}
200  {"OrderId":"ORD-2","CustomerName":null,"Quantity":3}
```

Second run, with `options.Serializer = new NewtonsoftJsonObjectSerializer()` and without `AllowSynchronousIO`:

```
200 {"OrderId":"ORD-2","customer_name":"Grace","Quantity":3}
```

There were no `Synchronous operations are disallowed` lines in the host log. The remaining field names are in PascalCase in both runs. Without the integration and with the default serializer, **every** field name in the response differs from the in-process response. With the integration, only one does.

## Sources

- [Guide for running C# Azure Functions in an isolated worker process](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide)
- [MicrosoftDocs/azure-docs#128734](https://github.com/MicrosoftDocs/azure-docs/pull/128734): note in the migration guide that Newtonsoft attributes are ignored silently
- [Azure/azure-functions-dotnet-worker#2131](https://github.com/Azure/azure-functions-dotnet-worker/issues/2131)
- [Azure/azure-functions-dotnet-worker#1979](https://github.com/Azure/azure-functions-dotnet-worker/issues/1979)
- A [blog post by Edi Wang](https://edi.wang/post/2024/2/7/json-serialization-caveat-in-azure-function) from February 2024 describes that Azure Functions binds with Newtonsoft by default. This does not apply to the pattern being tested here.
- A search for this exact pattern (Newtonsoft attribute on the DTO, default serializer of the isolated worker) revealed that this silent behavior was not described anywhere in official channels at the time. The migration guide now covers it via the PR above.
- The symptom, input paths, and the three cross-checks are my own reproduced measurements.
