# HTTP 200, und die Daten fehlen: Der Weg auf .NET 10 und den Isolated Worker

Demo-Repository für einen Vortrag über zwei parallel laufende Fristen, die Azure Functions bis zum **10. November 2026** betreffen. An diesem Tag endet der Support für .NET 8 und .NET 9, endet die Unterstützung des In-Process-Modells und es erscheint .NET 11. Der Vortrag stellt an einer kleinen Demo-Anwendung jeden gezeigten Fehler gezielt her und löst ihn wieder auf, einschließlich der Fälle, die unbemerkt bleiben: 200 OK, leeres Feld, kein Fehlerlog.

Dieses Repository ist das Artefakt des Vortrags. Jeder Zustand steckt in einem eigenen Git-Tag. Jede dokumentierte Fehlermeldung wurde tatsächlich erzeugt.

**Zur Sprache.** Diese Seite ist der kurze deutsche Begleiter zum Vortrag. Der vollständige Einstieg mit allen gemessenen Antworten, Tabellen und Auflösungswegen steht in [`README.md`](README.md) auf Englisch. Die Falldokumentation unter [`docs/`](docs/) ist ebenfalls englisch und trägt die Belege: Fehlermeldungen im Wortlaut, gemessene Antworten, Gegenproben, Quellen. Die Erklärung steht im Artikel.

## Voraussetzungen

- .NET SDK 8 und .NET SDK 10 (`dotnet --list-sdks`)
- Azure Functions Core Tools 4.x (`func --version`)
- Docker Desktop (für Azurite als lokalen Storage-Emulator)
- Git

Kein Azure-Abonnement, kein Netzwerkzugriff zur Laufzeit. Alle Fälle laufen lokal.

Der Artikel zu diesem Repository: [After the migration: What to do once your Function App is up and running again](https://blog.fzankl.de/azure-functions-isolated-worker-after-migration).

Die Isolated-Worker-Stände bauen über das MSBuild-SDK [`Azure.Functions.Sdk`](https://www.nuget.org/packages/Azure.Functions.Sdk/) 1.0.1, das den früheren `PackageReference` auf `Microsoft.Azure.Functions.Worker.Sdk` ablöst. Es wird beim ersten Build wie jedes andere Paket von nuget.org geholt, es ist nichts vorab zu installieren. `baseline-inprocess` bleibt davon unberührt und baut weiterhin mit dem Projekt-SDK `Microsoft.NET.Sdk` und dem Paket `Microsoft.NET.Sdk.Functions`.

## Zustand herstellen

```bash
docker run -d --name azurite-demo -p 10000:10000 -p 10001:10001 -p 10002:10002 \
  mcr.microsoft.com/azure-storage/azurite

git checkout serializer-attributes-broken
cd src/OrderProcessor
dotnet build # schlägt nur bei output-binding-broken absichtlich fehl
dotnet run
```

`dotnet run` ist der Weg für jeden Isolated-Worker-Tag. Die eine Ausnahme ist `baseline-inprocess`: Dieses Projekt ist eine Bibliothek, `dotnet run` bricht dort ab. Diesen Tag mit `func start` starten.

Jeder lokal lauffähige Fall hat seine eigene `.http`-Datei unter `http/`, nutzbar mit der REST-Client-Erweiterung von VS Code oder mit `curl`:

```bash
curl -X POST http://localhost:7071/api/orders \
  -H "Content-Type: application/json" \
  -d '{"OrderId":"ORD-5","customer_name":"Ada","Quantity":1}'
```

`docs/` liegt ausschließlich auf `main` und ist in keinem Tag enthalten. Unter einem ausgecheckten Tag findet man Code, `http/` und eine kurze englische README, die auf `main` verweist, beim Schlussbild zusätzlich `aspire/`, aber kein `docs/`-Verzeichnis.

## Abgebildete Zustände

Die Nummerierung ist dieselbe wie in [`README.md`](README.md) und im Vortrag.

| Reihenfolge | Fall                                                        | Tag                                      | Was zu sehen ist                                                                                                                                             |
| ----------- | ----------------------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1           | Ausgangslage: In-Process auf .NET 8                         | `baseline-inprocess`                     | Lauffähiger Ausgangsstand, `HttpRequest` hinein, `IActionResult` heraus, noch kein Fehler                                                                    |
| 2           | Output Binding: `out` gibt es nicht mehr                    | `output-binding-broken`                  | Output-Binding als `out`-Parameter: Compile-Fehler `CS0592`                                                                                                  |
| 3           | ↳ Auflösung                                                 | `output-binding-fixed`                   | Rückgabeklasse mit `[QueueOutput]` und `[HttpResult]`. Kompiliert, läuft noch nicht                                                                          |
| 4           | Synchrones Lesen: Die Zeile, die jahrelang funktioniert hat | `sync-read-broken`                       | `StreamReader(req.Body).ReadToEnd()` auf dem Kestrel-Stream: 500, `Synchronous operations are disallowed`                                                    |
| 5           | ↳ Auflösung                                                 | `sync-read-fixed`                        | `AllowSynchronousIO = true`. Der Fehler HTTP 500 aus dem Lesen ist weg, der nächste steht sofort da                                                          |
| 6           | Logger-Parameter: Der Host startet sauber                   | `logger-parameter-broken`                | `ILogger` als blanker Parameter: Route wird indexiert, jeder Aufruf endet mit `ArgumentNullException`                                                        |
| 7           | ↳ Auflösung                                                 | `logger-parameter-fixed`                 | Instanzklasse mit Konstruktor-Injektion. 200, Wert richtig, Feldname bereits `customerName`                                                                  |
| 8           | Serialisierungsattribute: 200, und das Feld ist leer        | `serializer-attributes-broken`           | Der saubere Fix für den Fehler HTTP 500 (`ReadFromJsonAsync`) erzeugt den unbemerkten Fehler                                                                 |
| 9           | ↳ Der Fix, den man überall findet                           | `serializer-attributes-worker-noop`      | `WorkerOptions.Serializer` auf Newtonsoft gesetzt: keine Wirkung, keine Meldung                                                                              |
| 10          | ↳ Auflösung A                                               | `serializer-attributes-fixed-stj`        | `[JsonPropertyName]`                                                                                                                                         |
| 11          | ↳ Auflösung B                                               | `serializer-attributes-fixed-newtonsoft` | `AddControllers().AddNewtonsoftJson()` plus expliziter Newtonsoft-Lesevorgang                                                                                |
| 11a         | ↳ Auflösung C *(abseits des Demopfads)*                     | `serializer-attributes-fixed-frombody`   | Derselbe Schalter, aber `[FromBody]` statt Lesevorgang: kleinster Migrationsdiff                                                                             |
| 12          | Logfilter: Die Logs sind weg                                | `log-filter-broken`                      | Application-Insights-Standardfilter verschluckt `LogInformation`                                                                                             |
| 13          | ↳ Auflösung                                                 | `log-filter-fixed`                       | Filterregel entfernt                                                                                                                                         |
| 14          | Slot-Swap: Grün geswappt, tot in Produktion                 | *(kein Tag)*                             | Staging-Slot-Swap in Azure, beide Fehlerbilder durchgespielt, siehe [`docs/slot-swap.md`](docs/slot-swap.md)                                                 |
| 15          | Zielstand: Und dann ist da noch die Version                 | `target-net10`                           | .NET 10, isolated, alle Auflösungen, plus zwei Zusatzbeispiele: DI-Prüfung beim Start (Worker 2.x) und `null` aus der Konfigurationsbindung (neu in .NET 10) |
| 16          | Schlussbild (optional)                                      | `aspire-optional`                        | Siehe [`docs/aspire.md`](docs/aspire.md), nur nach Abschluss aller übrigen Fälle                                                                             |

`git tag` sortiert alphabetisch und nicht nach dem Weg durch die Migration. Für die tatsächliche Reihenfolge:

```bash
git tag --sort=creatordate
```

Ab `log-filter-broken` setzt der Code auf Auflösung A auf, nicht auf B: Tag 12 folgt in der Historie auf Tag 11, liest aber wieder mit `ReadFromJsonAsync`, nutzt `[JsonPropertyName]` und hat beide Newtonsoft-Pakete entfernt. `target-net10` behält diesen Stand.

Fall 14 hat keinen Tag und läuft nicht lokal. Er braucht eine echte Azure-Umgebung mit zwei Slots.

## Prüfskript

`scripts/verify-all.ps1` baut jeden lokal lauffähigen Tag außer `aspire-optional` in einem eigenen Git-Worktree, startet die lauffähigen Stände und prüft die Zusagen aus der Falldokumentation. Ein fehlschlagender Tag bricht den Lauf nicht ab: Das Skript prüft alle Tags und endet mit Fehlercode, wenn eine Prüfung fehlgeschlagen ist.

```powershell
.\scripts\verify-all.ps1 baseline-inprocess serializer-attributes-fixed-frombody
```

Es ist als Beleg gedacht, nicht als allgemeines Werkzeug.

## Abgrenzung

Keine Datenbank, keine Authentifizierung, keine weiteren Trigger. Jede zusätzliche Zeile hätte in der Demo abgelenkt. Durable Functions werden nicht angefasst, siehe [`docs/target-net10.md`](docs/target-net10.md). Aspire steht bewusst nicht im Hauptpfad, Begründung in [`docs/aspire.md`](docs/aspire.md).

## Lizenz

Der Code (`src/`, `aspire/`, `http/`, `scripts/` und die Konfigurationsdateien) steht unter der [MIT-Lizenz](LICENSE). Die Dokumentation (`docs/` und die READMEs) steht unter [CC BY 4.0](LICENSE-docs). Beides © 2026 Fabian Zankl.
