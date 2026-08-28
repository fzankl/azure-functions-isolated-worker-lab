using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Variante B: auf Newtonsoft bleiben, aber in der Schicht, die die Antwort
// tatsächlich schreibt. Das ist die MVC-Formatierschicht von ASP.NET Core,
// nicht WorkerOptions.Serializer. Siehe docs/serializer-attributes.md.
builder.Services.AddControllers().AddNewtonsoftJson();

builder.Build().Run();
