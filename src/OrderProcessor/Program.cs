using Azure.Core.Serialization;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Der Fix, den man zu diesem Symptom überall findet: den Serialisierer der
// Worker-Pipeline auf Newtonsoft umstellen, damit [JsonProperty] wieder greift.
//
// Hier bleibt er wirkungslos. Antwort und Request laufen mit
// ASP.NET-Core-Integration nicht über WorkerOptions.Serializer, sondern über
// die JSON-Schicht von ASP.NET Core. Siehe docs/serializer-attributes.md.
builder.Services.Configure<WorkerOptions>(options =>
{
    options.Serializer = new NewtonsoftJsonObjectSerializer();
});

builder.Build().Run();
