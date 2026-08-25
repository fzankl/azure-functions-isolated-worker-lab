using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// AllowSynchronousIO ist entfallen: der Body wird jetzt asynchron gelesen.
// Damit ist der 500er aus docs/sync-read.md weg - und der stille Fehler da.

builder.Build().Run();
