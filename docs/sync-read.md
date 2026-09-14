# Synchronous Read: The Line That Worked for Years in the In-Process Model

**Tags:** `sync-read-broken`, `sync-read-fixed`

> **Article reference:** Section "Synchronous Operations Are Disallowed: The Explicit Error" in [After the migration](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration). This page documents where the information in the article comes from.

## The Stack Trace Verbatim

`dotnet build` runs without errors or warnings. `POST /api/orders` with a valid body returns HTTP 500. Reproduced with `dotnet run`, `sync-read-broken`, .NET 8:

```
System.Private.CoreLib: Exception while executing function: Functions.Order. System.Private.CoreLib: Result: Failure
Type: System.InvalidOperationException
Exception: Synchronous operations are disallowed. Call ReadAsync or set AllowSynchronousIO to true instead.
Stack:    at Microsoft.AspNetCore.Server.Kestrel.Core.Internal.Http.HttpRequestStream.Read(Byte[] buffer, Int32 offset, Int32 count)
   at System.IO.StreamReader.ReadBuffer()
   at System.IO.StreamReader.ReadToEnd()
   at OrderProcessor.OrderFunction.Run(HttpRequest req, ILogger log) in ...\src\OrderProcessor\OrderFunction.cs:line 16
   at OrderProcessor.DirectFunctionExecutor.ExecuteAsync(FunctionContext context) in ...\GeneratedFunctionExecutor.g.cs:line 32
   at Microsoft.Azure.Functions.Worker.OutputBindings.OutputBindingsMiddleware.Invoke(FunctionContext context, FunctionExecutionDelegate next) in /_/src/DotNetWorker.Core/OutputBindings/OutputBindingsMiddleware.cs:line 13
   at Microsoft.Azure.Functions.Worker.Extensions.Http.AspNetCore.FunctionsHttpProxyingMiddleware.Invoke(FunctionContext context, FunctionExecutionDelegate next) in /_/extensions/Worker.Extensions.Http.AspNetCore/src/FunctionsMiddleware/FunctionsHttpProxyingMiddleware.cs:line 54
   at Microsoft.Azure.Functions.Worker.FunctionsApplication.InvokeFunctionAsync(FunctionContext context) in /_/src/DotNetWorker.Core/FunctionsApplication.cs:line 83
   at Microsoft.Azure.Functions.Worker.Handlers.InvocationHandler.InvokeAsync(InvocationRequest request) in /_/src/DotNetWorker.Grpc/Handlers/InvocationHandler.cs:line 91.
```

Three lines in the stack trace carry the case: the first line `Kestrel...HttpRequestStream.Read`, below it the carried-over line `OrderFunction.cs:line 16`, and further down the line `FunctionsHttpProxyingMiddleware`, which relates to the ASP.NET Core integration.

## The Template Reads Asynchronously

Generated using `func init --worker-runtime dotnet --target-framework net8.0` and `func new --template "HTTP trigger"`:

```csharp
public static async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", "post", Route = null)] HttpRequest req,
    ILogger log)
{
    ...
    string requestBody = await new StreamReader(req.Body).ReadToEndAsync();
    dynamic data = JsonConvert.DeserializeObject(requestBody);
```

The official template reads asynchronously and has no output binding. Synchronous reading is only introduced in `baseline-inprocess`. There, the queue output binding is defined as an `out` parameter, and a method with an `out` parameter cannot be `async` (`error CS1988: Async methods cannot have ref, in or out parameters`). Consequently, `ReadToEndAsync()` is not applicable.

With `output-binding-fixed`, the `out` parameter is removed and replaced with `OrderFunctionResult`. The reason for the synchronous reading is thus eliminated, but the line remains. This specific line now triggers HTTP 500.

## The Condition in the Guide Was Too Restrictive

The guide imposed a restriction on `AllowSynchronousIO` in the code comment:

```csharp
// Only needed if using HttpRequestData/HttpResponseData and a serializer that doesn't support asynchronous IO
```

However, HTTP 500 also occurs with `HttpRequest` and `IActionResult`, **without** `HttpRequestData`, **without** `HttpResponseData`, and **without** a configured serializer. It is sufficient to have a synchronous `StreamReader` call with the integration enabled.

This check led to [MicrosoftDocs/azure-docs#128726](https://github.com/MicrosoftDocs/azure-docs/pull/128726) (merged).

## Resolution: `AllowSynchronousIO` (`sync-read-fixed`)

In `Program.cs`:

```csharp
builder.Services.Configure<KestrelServerOptions>(options => options.AllowSynchronousIO = true);
```

This resolves the HTTP 500 from the read. The call still ends with HTTP 500, but now with `ArgumentNullException: Value cannot be null. (Parameter 'logger')`. This is the next issue, see [`logger-parameter.md`](logger-parameter.md).

## The Alternative: Asynchronous Reading

The cleaner solution is to read the body asynchronously, for example, using `ReadFromJsonAsync`. It is not tagged here because `AllowSynchronousIO` resolves the case in isolation. The asynchronous reading is present in the first tag of the serialization case (`serializer-attributes-broken`), where it brings the next error, see [`serializer-attributes.md`](serializer-attributes.md).

## Sources

- [Guide for running C# Azure Functions in an isolated worker process](https://learn.microsoft.com/en-us/azure/azure-functions/dotnet-isolated-process-guide)
- [MicrosoftDocs/azure-docs#128726](https://github.com/MicrosoftDocs/azure-docs/pull/128726)
- [Kestrel configuration, `AllowSynchronousIO`](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/kestrel/options)
- [Azure/azure-functions-dotnet-worker#2184](https://github.com/Azure/azure-functions-dotnet-worker/issues/2184): the same exception via `HttpResponseData.WriteString()`, without any serializer
- [Azure/azure-functions-dotnet-worker#2459](https://github.com/Azure/azure-functions-dotnet-worker/issues/2459): the same exception with Newtonsoft on the response stream
- The stack trace, the resolution via `AllowSynchronousIO`, and the evidence that the condition in the guide was too restrictive are my own reproduced measurements.