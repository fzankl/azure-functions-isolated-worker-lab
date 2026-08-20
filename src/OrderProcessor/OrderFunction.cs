using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;

namespace OrderProcessor;

public static class OrderFunction
{
    [Function("Order")]
    public static IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req,
        [QueueOutput("orders")] out string message,
        ILogger log)
    {
        string body = new StreamReader(req.Body).ReadToEnd();
        var order = JsonConvert.DeserializeObject<OrderRequest>(body);

        if (order is null || string.IsNullOrWhiteSpace(order.OrderId) || order.Quantity <= 0)
        {
            log.LogWarning("Rejected invalid order payload.");
            message = string.Empty;
            return new BadRequestObjectResult("OrderId must be set and Quantity must be greater than zero.");
        }

        log.LogInformation("Order {OrderId} for {CustomerName} accepted.", order.OrderId, order.CustomerName);

        message = JsonConvert.SerializeObject(order);

        return new OkObjectResult(order);
    }
}

public class OrderRequest
{
    public string? OrderId { get; set; }

    [JsonProperty("customer_name")]
    public string? CustomerName { get; set; }

    public int Quantity { get; set; }
}
