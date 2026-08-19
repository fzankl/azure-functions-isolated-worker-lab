# HTTP 200, and the Data Is Gone: A Runnable Azure Functions Migration Sample

You are looking at **one tagged state** of this repository: the in-process starting point, before the migration to the isolated worker model. Every later tag reproduces one failure that shows up on the way, or the resolution of one.

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
func start
```

This state needs `func start`, unlike the isolated tags that use `dotnet run`. An in-process project is a library that the host loads, not an executable. `dotnet run` refuses it with *"The current OutputType is 'Library'"*. It also needs `FUNCTIONS_INPROC_NET8_ENABLED=1`, which is already set in `local.settings.json`.

## License

The code in this tag is licensed under the [MIT License](LICENSE), this README under [CC BY 4.0](LICENSE-docs). Both © 2026 Fabian Zankl.
