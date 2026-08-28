using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;

namespace OrderProcessor;

public sealed class OrderFunction
{
    private readonly ILogger<OrderFunction> _logger;

    public OrderFunction(ILogger<OrderFunction> logger) => _logger = logger;

    // Variante B liest den Body ausdrücklich mit Newtonsoft. Das ist nötig, weil
    // AddControllers().AddNewtonsoftJson() in Program.cs nur die Antwort abdeckt:
    // ReadFromJsonAsync<T>() bliebe System.Text.Json und damit bei customer_name == null.
    //
    // Kürzere Alternative, gemessen am 2026-08-22, liefert dasselbe Ergebnis:
    //
    //     [Function("Order")]
    //     public OrderFunctionResult Run(
    //         [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req,
    //         [Microsoft.Azure.Functions.Worker.Http.FromBody] OrderRequest order)
    //
    // Voll qualifiziert, und das ist kein Schönheitsfehler: In dieser Datei steht wegen
    // IActionResult bereits using Microsoft.AspNetCore.Mvc. Wer zusätzlich
    // using Microsoft.Azure.Functions.Worker.Http ergänzt und dann kurz [FromBody] schreibt,
    // bekommt error CS0104 - "FromBody" ist ein mehrdeutiger Verweis. Gemessen am 2026-08-22.
    //
    // [FromBody] ist der einzige Eingangspfad, den AddNewtonsoftJson() mitrepariert; es zieht
    // seine Deserialisierung aus der MVC-Formatierschicht. Genau darum geht es in
    // Azure/azure-functions-dotnet-worker#2131, und deshalb durfte das Issue mit
    // AddMvc().AddNewtonsoftJson() als Antwort geschlossen werden.
    //
    // Ohne AddNewtonsoftJson() bindet auch [FromBody] nach System.Text.Json-Regeln, also
    // ebenfalls mit customer_name == null. Das Attribut vermeidet den Fehler nicht, es ist
    // nur der Pfad, auf dem der Fix ankommt.
    //
    // Hier bewusst nicht verwendet: Der explizite Lesevorgang macht sichtbar, dass Eingang und
    // Ausgang zwei getrennte Schichten sind. Mit [FromBody] verschwindet genau das aus dem Blick.
    //
    // Achtung: Fehlt der Worker.Http-Namensraum, bindet kurzes [FromBody] an das
    // MVC-Attribut - das kompiliert ohne Warnung und bindet nicht. Siehe
    // docs/serializer-attributes.md.
    [Function("Order")]
    public async Task<OrderFunctionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req)
    {
        string body = await new StreamReader(req.Body).ReadToEndAsync();
        var order = JsonConvert.DeserializeObject<OrderRequest>(body);

        if (order is null || string.IsNullOrWhiteSpace(order.OrderId) || order.Quantity <= 0)
        {
            _logger.LogWarning("Rejected invalid order payload.");
            return new OrderFunctionResult
            {
                HttpResponse = new BadRequestObjectResult("OrderId must be set and Quantity must be greater than zero.")
            };
        }

        _logger.LogInformation("Order {OrderId} for {CustomerName} accepted.", order.OrderId, order.CustomerName);

        return new OrderFunctionResult
        {
            QueueMessage = JsonConvert.SerializeObject(order),
            HttpResponse = new OkObjectResult(order)
        };
    }
}

public class OrderFunctionResult
{
    [QueueOutput("orders")]
    public string? QueueMessage { get; set; }

    [HttpResult]
    public IActionResult? HttpResponse { get; set; }
}

public class OrderRequest
{
    public string? OrderId { get; set; }

    [JsonProperty("customer_name")]
    public string? CustomerName { get; set; }

    public int Quantity { get; set; }
}
