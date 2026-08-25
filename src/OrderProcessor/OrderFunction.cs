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

    [Function("Order")]
    public async Task<OrderFunctionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "orders")] HttpRequest req)
    {
        var order = await req.ReadFromJsonAsync<OrderRequest>();

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
