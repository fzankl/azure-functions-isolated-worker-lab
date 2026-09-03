using Aspire.Hosting;
using Aspire.Hosting.Azure;

var builder = DistributedApplication.CreateBuilder(args);

var storage = builder.AddAzureStorage("storage")
    .RunAsEmulator();

var queues = storage.AddQueues("queues");

builder.AddAzureFunctionsProject<Projects.OrderProcessor>("orderprocessor")
    .WithHostStorage(storage)
    .WithReference(queues);

builder.Build().Run();
