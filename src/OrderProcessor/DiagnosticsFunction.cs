using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace OrderProcessor;

public sealed class DiagnosticsFunction
{
    private readonly ILogger<DiagnosticsFunction> _logger;
    private readonly LoggerFilterOptions _filterOptions;

    public DiagnosticsFunction(ILogger<DiagnosticsFunction> logger, IOptions<LoggerFilterOptions> filterOptions)
    {
        _logger = logger;
        _filterOptions = filterOptions.Value;
    }

    [Function("Diagnostics")]
    public IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "diagnostics/log-filters")] HttpRequest req)
    {
        _logger.LogInformation("LoggerFilterOptions.Rules ({Count} total):", _filterOptions.Rules.Count);

        var rules = new List<object>();
        foreach (var rule in _filterOptions.Rules)
        {
            _logger.LogInformation(
                "Provider={Provider} Category={Category} MinLevel={MinLevel}",
                rule.ProviderName ?? "(any)",
                rule.CategoryName ?? "(any)",
                rule.LogLevel?.ToString() ?? "(unset)");

            rules.Add(new { rule.ProviderName, rule.CategoryName, LogLevel = rule.LogLevel?.ToString() });
        }

        return new OkObjectResult(rules);
    }
}
