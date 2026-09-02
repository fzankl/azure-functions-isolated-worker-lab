using OrderProcessor;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Services.Configure<LoggerFilterOptions>(options =>
{
    var defaultRule = options.Rules.FirstOrDefault(rule =>
        rule.ProviderName == "Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider");
    if (defaultRule is not null)
    {
        options.Rules.Remove(defaultRule);
    }
});

builder.Services.Configure<RetryOptions>(builder.Configuration.GetSection("Retry"));

// Demo switch for docs/target-net10.md: a Scoped-in-Singleton registration that
// only fails Build() under ValidateOnBuild/ValidateScopes (Development).
if (string.Equals(Environment.GetEnvironmentVariable("ENABLE_BAD_DI_REGISTRATION"), "true", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddScoped<IScopedDependency, ScopedDependency>();
    builder.Services.AddSingleton<SingletonConsumer>();
}

builder.Build().Run();
