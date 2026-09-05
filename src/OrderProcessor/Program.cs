using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Variante C: unverändert gegenüber Variante B. Der Schalter für die Antwort
// ist derselbe; neu ist nur, dass [FromBody] in OrderFunction.cs jetzt auch den
// Eingang über diese Schicht laufen lässt.
//
// Bewusst OHNE ContractResolver. DefaultContractResolver würde PascalCase
// liefern - das In-Process-Modell hat aber camelCase geliefert, siehe
// docs/baseline-inprocess.md. Der Resolver würde die Übereinstimmung mit dem
// alten Vertrag also zerstören statt herstellen.
builder.Services.AddControllers().AddNewtonsoftJson();

builder.Build().Run();
