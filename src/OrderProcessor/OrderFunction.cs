using System.IO;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Extensions.Http;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;

namespace OrderProcessor;

public static class OrderFunction
{
    [FunctionName("Order")]
    public static IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req,
        [Queue("orders")] out string message,
        ILogger log)
    {
        // Synchron gelesen, und das ist hier erzwungen, nicht nachlässig: Die
        // Queue-Ausgabebindung steht oben als out-Parameter, und eine Methode mit
        // out-Parameter darf nicht async sein (error CS1988). Damit scheidet
        // await ReadToEndAsync() aus.
        //
        // Die offizielle In-Process-Vorlage (func new --template "HTTP trigger") liest
        // asynchron. Sobald aber eine Ausgabebindung als out-Parameter dazukommt - im
        // In-Process-Modell die idiomatische Form -, geht das nicht mehr.
        //
        // Genau diese Zeile wird nach der Migration zum 500er: siehe docs/sync-read.md.
        // Das out-Binding und der synchrone Lesevorgang haben also dieselbe Wurzel.
        string body = new StreamReader(req.Body).ReadToEnd();
        var order = JsonConvert.DeserializeObject<OrderRequest>(body);

        if (order is null || string.IsNullOrWhiteSpace(order.OrderId) || order.Quantity <= 0)
        {
            log.LogWarning("Rejected invalid order payload.");
            message = null;
            return new BadRequestObjectResult("OrderId must be set and Quantity must be greater than zero.");
        }

        log.LogInformation("Order {OrderId} for {CustomerName} accepted.", order.OrderId, order.CustomerName);

        message = JsonConvert.SerializeObject(order);

        return new OkObjectResult(order);
    }
}

public class OrderRequest
{
    public string OrderId { get; set; }

    [JsonProperty("customer_name")]
    public string CustomerName { get; set; }

    public int Quantity { get; set; }
}
