using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Der aus dem In-Process-Modell übernommene StreamReader liest den Request-Body
// synchron. Mit ASP.NET-Core-Integration liegt darunter der Kestrel-Stream, und
// der verbietet synchrones Lesen standardmäßig. Siehe docs/sync-read.md.
builder.Services.Configure<KestrelServerOptions>(options => options.AllowSynchronousIO = true);

builder.Build().Run();
