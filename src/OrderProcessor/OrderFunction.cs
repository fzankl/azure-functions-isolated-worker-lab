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

    // Variante C: der kleinste Migrationsdiff.
    //
    // Gegenüber Variante B (serializer-attributes-fixed-newtonsoft) fällt der
    // manuelle Lesevorgang ersatzlos weg. [FromBody] aus Worker.Http zieht seine
    // Deserialisierung aus der MVC-Formatierschicht, und die steht durch
    // AddControllers().AddNewtonsoftJson() in Program.cs auf Newtonsoft. Damit
    // laufen Eingang und Ausgang über denselben Serialisierer, und das DTO
    // bleibt unverändert - inklusive [JsonProperty("customer_name")].
    //
    // Gemessen: der Antwortkörper ist byte-identisch mit dem des In-Process-
    // Stands, siehe docs/baseline-inprocess.md. 400 beim Regelverstoß und 500
    // bei kaputtem JSON verhalten sich ebenfalls wie vorher.
    //
    // Die volle Qualifizierung ist Pflicht, nicht Stil. In dieser Datei steht
    // wegen IActionResult bereits using Microsoft.AspNetCore.Mvc. Kurzes
    // [FromBody] ist damit mehrdeutig (error CS0104), und wenn nur der
    // MVC-Namensraum sichtbar ist, kompiliert es ohne Warnung und bindet nicht.
    //
    // AllowSynchronousIO wird gegenstandslos: die Bindung liest asynchron, im
    // eigenen Code steht kein StreamReader mehr.
    //
    // Warum der Vortrag trotzdem Variante B zeigt: Der explizite Lesevorgang
    // macht sichtbar, dass Eingang und Ausgang zwei getrennte Schichten sind.
    // Für eine echte Migration ist die Reihenfolge umgekehrt. Siehe
    // docs/serializer-attributes.md.
    [Function("Order")]
    public OrderFunctionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req,
        [Microsoft.Azure.Functions.Worker.Http.FromBody] OrderRequest order)
    {
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
