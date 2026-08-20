# HTTP 200, and the Data Is Gone: A Runnable Azure Functions Migration Sample

You are looking at **one tagged state** of this repository. Each tag reproduces a single failure that shows up when a C# function app is migrated from the in-process model to the isolated worker model, or the resolution of one.

**The documentation is on `main`, not here.** A tag would freeze it at its own moment, and that moment is stale after the next correction. The same reason keeps `docs/` off the tags.

- [Overview, tag list and every measured response](https://github.com/fzankl/azure-functions-isolated-worker-lab/blob/main/README.md)
- [`docs/`: per case the symptom, cause, resolution, verbatim error message and source](https://github.com/fzankl/azure-functions-isolated-worker-lab/tree/main/docs)
- [German companion for the talk](https://github.com/fzankl/azure-functions-isolated-worker-lab/blob/main/README.de.md)

What is here is what you need to run this one state: the code under `src/` and the matching calls under `http/`.

```bash
docker run -d --name azurite-demo -p 10000:10000 -p 10001:10001 -p 10002:10002 \
  mcr.microsoft.com/azure-storage/azurite

cd src/OrderProcessor
dotnet build
dotnet run
```

`dotnet run` starts the Functions host. This state builds with the `Azure.Functions.Sdk` 1.0.1 MSBuild SDK, and running it needs the Azure Functions Core Tools installed.

Several tags fail on purpose: the build breaks, a call returns 500, or a 200 comes back with a field silently gone. Which one does what is in the tag list linked above.

## License

The code in this tag is licensed under the [MIT License](LICENSE), this README under [CC BY 4.0](LICENSE-docs). Both © 2026 Fabian Zankl.
