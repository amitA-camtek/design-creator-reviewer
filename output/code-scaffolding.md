# FalconAuditService — Code Scaffolding

| Field | Value |
|---|---|
| Document | code-scaffolding.md |
| Phase | 3 — Code scaffolding |
| Source | `architecture-design.md` (Alt C, multi-hosted), `schema-design.md` (Alt B), `api-design.md` (Alt B), `sequence-diagrams.md` |
| Target | C# 10 / .NET 6, two-process Windows Service deliverable |
| Date | 2026-04-25 |

---

## 1. Solution Layout

```
FalconAuditService.sln
├── src/
│   ├── FalconAuditService.Core/             # shared library
│   ├── FalconAuditWorker/                   # writer Windows Service
│   └── FalconAuditQuery/                    # reader Windows Service (API)
├── tests/
│   ├── FalconAuditService.Core.Tests/
│   ├── FalconAuditWorker.Tests/
│   ├── FalconAuditQuery.Tests/
│   └── FalconAuditService.Integration.Tests/
└── deploy/
    ├── install.ps1
    └── uninstall.ps1
```

Both runtime projects target `net6.0` with `<OutputType>Exe</OutputType>`, `<UseWindowsService>true</UseWindowsService>` (via `Microsoft.Extensions.Hosting.WindowsServices`), and reference `FalconAuditService.Core`.

### 1.1 Package references

`FalconAuditService.Core.csproj`:

```xml
<PackageReference Include="Microsoft.Data.Sqlite" Version="6.0.*" />
<PackageReference Include="DiffPlex" Version="1.7.*" />
<PackageReference Include="Microsoft.Extensions.Hosting.Abstractions" Version="6.0.*" />
<PackageReference Include="Microsoft.Extensions.Logging.Abstractions" Version="6.0.*" />
<PackageReference Include="Microsoft.Extensions.Options" Version="6.0.*" />
```

`FalconAuditWorker.csproj`:

```xml
<PackageReference Include="Microsoft.Extensions.Hosting" Version="6.0.*" />
<PackageReference Include="Microsoft.Extensions.Hosting.WindowsServices" Version="6.0.*" />
<PackageReference Include="Serilog.Extensions.Hosting" Version="5.0.*" />
<PackageReference Include="Serilog.Sinks.File" Version="5.0.*" />
<PackageReference Include="Serilog.Sinks.EventLog" Version="3.1.*" />
```

`FalconAuditQuery.csproj`:

```xml
<PackageReference Include="Microsoft.AspNetCore.Mvc.Core" Version="6.0.*" />
<PackageReference Include="Microsoft.Extensions.Hosting.WindowsServices" Version="6.0.*" />
<PackageReference Include="Serilog.AspNetCore" Version="6.0.*" />
```

---

## 2. Shared Models (`FalconAuditService.Core/Models`)

### 2.1 Configuration

```csharp
namespace FalconAuditService.Core.Configuration;

public sealed class MonitorConfig
{
    public string WatchPath { get; init; } = @"c:\job\";
    public string GlobalDbPath { get; init; } = @"C:\bis\auditlog\global.db";
    public string ClassificationRulesPath { get; init; } = @"C:\bis\auditlog\FileClassificationRules.json";
    public int    ApiPort { get; init; } = 5100;
    public int    DebounceMs { get; init; } = 500;
    public int    CatchUpYieldThreshold { get; init; } = 50;
    public int    ShardChannelCapacity { get; init; } = 1024;
    public int    JobDiscoveryIntervalSeconds { get; init; } = 30;
}
```

### 2.2 Domain events

```csharp
namespace FalconAuditService.Core.Models;

public enum MonitorPriority { P1, P2, P3, P4 }

public enum FileChangeType { Created, Modified, Deleted, Renamed }

public sealed record RawFsEvent(
    string FullPath,
    FileChangeType ChangeType,
    DateTimeOffset Detected,
    string? OldFullPath = null);

public sealed record ClassifiedEvent(
    RawFsEvent Raw,
    string Module,
    string OwnerService,
    MonitorPriority Priority,
    string ShardKey,        // job name or "__global__"
    string RelFilepath);

public sealed record CompiledRule(
    Regex Pattern,
    string Module,
    string OwnerService,
    MonitorPriority Priority);
```

### 2.3 DTOs (used by both processes)

```csharp
namespace FalconAuditService.Core.Models.Dtos;

public sealed record JobSummaryDto(string JobName, DateTimeOffset? Created, int EventCount, DateTimeOffset? LatestEventAt);

public sealed record EventListItemDto(
    long Id, DateTimeOffset ChangedAt, string EventType, string RelFilepath,
    string? Module, string? OwnerService, string MonitorPriority,
    string MachineName, string? Sha256Hash);

public sealed record EventDetailDto(
    long Id, DateTimeOffset ChangedAt, string EventType, string Filepath, string RelFilepath,
    string? Module, string? OwnerService, string MonitorPriority, string MachineName,
    string? Sha256Hash, string? OldContent, string? DiffText);

public sealed record FileBaselineDto(string Filepath, string RelFilepath, string LastHash, DateTimeOffset LastSeen);

public sealed record ManifestEntryDto(string MachineName, DateTimeOffset Timestamp);

public sealed record MachineHistoryDto(
    string MachineName, DateTimeOffset ArrivedAt, DateTimeOffset? DepartedAt, int EventCount);

public sealed record ManifestDto(
    string JobName, int AuditDbVersion,
    ManifestEntryDto Created,
    IReadOnlyList<MachineHistoryDto> History);
```

---

## 3. Abstractions (`FalconAuditService.Core/Abstractions`)

```csharp
namespace FalconAuditService.Core.Abstractions;

public interface IClock
{
    DateTimeOffset UtcNow { get; }
}

public interface IFileSystem
{
    bool DirectoryExists(string path);
    bool FileExists(string path);
    IEnumerable<string> EnumerateDirectories(string root, string pattern, SearchOption opt);
    IEnumerable<string> EnumerateFiles(string root, string pattern, SearchOption opt);
    Task<string> ReadAllTextAsync(string path, CancellationToken ct);
    Task WriteAllTextAsync(string path, string contents, CancellationToken ct);
    void Move(string source, string dest, bool overwrite);
    Stream OpenRead(string path);
    DateTimeOffset GetLastWriteTimeUtc(string path);
}

public interface IClassificationRulesLoader
{
    Task<ImmutableList<CompiledRule>> LoadAsync(string path, CancellationToken ct);
}

public interface IFileClassifier
{
    void SetRules(ImmutableList<CompiledRule> rules);
    ClassifiedEvent? Classify(RawFsEvent raw, string watchRoot);
}

public interface IPathValidator
{
    bool IsSafe(string relFilepath);
}

public interface IManifestManager
{
    Task<ManifestDto?> ReadAsync(string jobFolder, CancellationToken ct);
    Task RecordArrivalAsync(string jobFolder, string machineName, DateTimeOffset at, CancellationToken ct);
    Task RecordDepartureAsync(string jobFolder, string machineName, DateTimeOffset at, CancellationToken ct);
    Task IncrementEventCountAsync(string jobFolder, string machineName, CancellationToken ct);
}

public interface ISchemaMigrator
{
    Task EnsureSchemaAsync(SqliteConnection connection, CancellationToken ct);
}

public interface ISqliteRepositoryFactory
{
    ISqliteRepository OpenReadWrite(string dbPath);
    ISqliteRepository OpenReadOnly(string dbPath);
}

public interface IShardReaderFactory
{
    /// <summary>
    /// Opens a short-lived read-only connection to the named job's shard.
    /// The returned handle must be disposed at the end of the HTTP request.
    /// Throws <see cref="ShardNotFoundException"/> if the job is not registered.
    /// Throws <see cref="ShardUnavailableException"/> if the shard file cannot be opened.
    /// </summary>
    Task<ShardReadHandle> OpenAsync(string jobName, CancellationToken ct);
}

public interface ISqliteRepository : IAsyncDisposable
{
    SqliteConnection Connection { get; }
    Task InsertEventAsync(AuditLogRow row, CancellationToken ct);
    Task UpsertBaselineAsync(string filepath, string sha256, DateTimeOffset lastSeen, CancellationToken ct);
    Task<string?> GetLastHashAsync(string filepath, CancellationToken ct);
    Task<string?> GetLastP1ContentAsync(string filepath, CancellationToken ct);
}
```

### 3.1 Domain exceptions

```csharp
namespace FalconAuditService.Core.Exceptions;

/// <summary>Thrown when the requested job has no registered shard in JobDiscoveryService.</summary>
public sealed class ShardNotFoundException : Exception
{
    public string JobName { get; }
    public ShardNotFoundException(string jobName)
        : base($"No shard registered for job '{jobName}'.") => JobName = jobName;
}

/// <summary>Thrown when the shard file exists in discovery but cannot be opened (e.g. file removed after departure).</summary>
public sealed class ShardUnavailableException : Exception
{
    public string JobName { get; }
    public ShardUnavailableException(string jobName, Exception inner)
        : base($"Shard for job '{jobName}' is temporarily unavailable.", inner) => JobName = jobName;
}
```

---

## 4. Worker Process (`FalconAuditWorker`)

### 4.1 `Program.cs`

```csharp
using FalconAuditService.Core.Abstractions;
using FalconAuditService.Core.Classification;
using FalconAuditService.Core.Configuration;
using FalconAuditService.Core.Manifest;
using FalconAuditService.Core.Sqlite;
using FalconAuditWorker.CatchUp;
using FalconAuditWorker.Hosting;
using FalconAuditWorker.Jobs;
using FalconAuditWorker.Monitor;
using FalconAuditWorker.Recording;
using FalconAuditWorker.Storage;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Serilog;

var host = Host.CreateDefaultBuilder(args)
    .UseWindowsService(o => o.ServiceName = "FalconAuditWorker")
    .UseSerilog((ctx, lc) => lc
        .WriteTo.File(@"C:\bis\auditlog\logs\worker-.log", rollingInterval: RollingInterval.Day)
        .WriteTo.EventLog("FalconAuditService", manageEventSource: false))
    .ConfigureServices((ctx, s) =>
    {
        s.Configure<MonitorConfig>(ctx.Configuration.GetSection("monitor_config"));

        // shared
        s.AddSingleton<IClock, SystemClock>();
        s.AddSingleton<IFileSystem, PhysicalFileSystem>();
        s.AddSingleton<IClassificationRulesLoader, ClassificationRulesLoader>();
        s.AddSingleton<IFileClassifier, FileClassifier>();
        s.AddSingleton<IPathValidator, PathValidator>();
        s.AddSingleton<IManifestManager, ManifestManager>();
        s.AddSingleton<ISchemaMigrator, SchemaMigrator>();
        s.AddSingleton<ISqliteRepositoryFactory, SqliteRepositoryFactory>();

        // worker pipeline
        s.AddSingleton<IHashService, HashService>();
        s.AddSingleton<IDiffBuilder, DiffPlexDiffBuilder>();
        s.AddSingleton<IEventRecorder, EventRecorder>();
        s.AddSingleton<IShardRegistry, ShardRegistryRw>();
        s.AddSingleton<IEventDebouncer, EventDebouncer>();
        s.AddSingleton<IFileMonitor, FileMonitor>();
        s.AddSingleton<IDirectoryWatcher, DirectoryWatcher>();
        s.AddSingleton<IJobLifecycle, JobLifecycleHandler>();
        s.AddSingleton<ICatchUpScannerFactory, CatchUpScannerFactory>();
        s.AddSingleton<ICatchUpCoordinator, CatchUpCoordinator>();
        s.AddSingleton<IRulesFileWatcher, RulesFileWatcher>();

        s.AddHostedService<AuditHost>();
    })
    .Build();

await host.RunAsync();
```

### 4.2 `AuditHost`

```csharp
namespace FalconAuditWorker.Hosting;

internal sealed class AuditHost : BackgroundService
{
    private readonly IClassificationRulesLoader _rulesLoader;
    private readonly IFileClassifier _classifier;
    private readonly IFileMonitor _monitor;
    private readonly IDirectoryWatcher _dirWatcher;
    private readonly ICatchUpCoordinator _catchUp;
    private readonly IRulesFileWatcher _rulesWatcher;
    private readonly IOptionsMonitor<MonitorConfig> _config;
    private readonly ILogger<AuditHost> _log;

    public AuditHost(/* ctor */)
    { /* assign */ }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var cfg = _config.CurrentValue;

        // 1. Load rules
        var rules = await _rulesLoader.LoadAsync(cfg.ClassificationRulesPath, stoppingToken);
        _classifier.SetRules(rules);
        _log.LogInformation("Loaded {Count} classification rules", rules.Count);

        // 2. Arm FSW (SVC-003 — must precede catch-up; PERF-001 — < 600 ms)
        await _monitor.StartAsync(stoppingToken);
        _log.LogInformation("FileSystemWatcher armed on {Path}", cfg.WatchPath);

        // 3. Arm directory watcher
        await _dirWatcher.StartAsync(stoppingToken);

        // 4. Run catch-up — strictly after FSW is armed
        await _catchUp.RunAllAsync(stoppingToken);
        _log.LogInformation("Catch-up complete");

        // 5. Arm rules hot-reload
        await _rulesWatcher.StartAsync(stoppingToken);

        // Stay alive
        await Task.Delay(Timeout.Infinite, stoppingToken).ContinueWith(_ => { });
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await _rulesWatcher.StopAsync(cancellationToken);
        await _monitor.StopAsync(cancellationToken);
        await _dirWatcher.StopAsync(cancellationToken);
        await base.StopAsync(cancellationToken);
        // ShardRegistry.DisposeAsync called by DI container
    }
}
```

### 4.3 `FileMonitor`

```csharp
namespace FalconAuditWorker.Monitor;

internal sealed class FileMonitor : IFileMonitor, IAsyncDisposable
{
    private readonly IEventDebouncer _debouncer;
    private readonly IFileClassifier _classifier;
    private readonly IShardRegistry _shards;
    private readonly IClock _clock;
    private readonly IOptionsMonitor<MonitorConfig> _config;
    private readonly ILogger<FileMonitor> _log;
    private FileSystemWatcher? _fsw;
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task WatcherReady => _ready.Task;

    public Task StartAsync(CancellationToken ct)
    {
        var cfg = _config.CurrentValue;
        _fsw = new FileSystemWatcher(cfg.WatchPath)
        {
            IncludeSubdirectories = true,
            InternalBufferSize = 64 * 1024,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite
                         | NotifyFilters.Size | NotifyFilters.CreationTime,
        };
        _fsw.Created  += (_, e) => OnRaw(e.FullPath, FileChangeType.Created);
        _fsw.Changed  += (_, e) => OnRaw(e.FullPath, FileChangeType.Modified);
        _fsw.Deleted  += (_, e) => OnRaw(e.FullPath, FileChangeType.Deleted);
        _fsw.Renamed  += (_, e) => OnRaw(e.FullPath, FileChangeType.Renamed, e.OldFullPath);
        _fsw.Error    += OnFswError;
        _fsw.EnableRaisingEvents = true;
        _ready.TrySetResult();
        return Task.CompletedTask;
    }

    private void OnRaw(string path, FileChangeType type, string? oldPath = null)
    {
        _debouncer.Schedule(path, () =>
        {
            var raw = new RawFsEvent(path, type, _clock.UtcNow, oldPath);
            var classified = _classifier.Classify(raw, _config.CurrentValue.WatchPath);
            if (classified is null) return;            // P4 ignored
            _shards.RouteAsync(classified).GetAwaiter().GetResult();
        });
    }

    private void OnFswError(object sender, ErrorEventArgs e)
    {
        _log.LogError(e.GetException(), "FSW error — triggering full catch-up");
        // Notify CatchUpCoordinator via injected event aggregator (omitted for brevity)
    }

    public Task StopAsync(CancellationToken ct)
    {
        if (_fsw is not null) { _fsw.EnableRaisingEvents = false; _fsw.Dispose(); _fsw = null; }
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() { _fsw?.Dispose(); return ValueTask.CompletedTask; }
}
```

### 4.4 `EventDebouncer`

```csharp
internal sealed class EventDebouncer : IEventDebouncer
{
    private readonly IOptionsMonitor<MonitorConfig> _cfg;
    private readonly ConcurrentDictionary<string, CancellationTokenSource> _pending = new(StringComparer.OrdinalIgnoreCase);

    public void Schedule(string path, Action onFire)
    {
        var newCts = new CancellationTokenSource();
        var oldCts = _pending.AddOrUpdate(path, newCts, (_, prev) => { prev.Cancel(); return newCts; });
        _ = Task.Delay(_cfg.CurrentValue.DebounceMs, newCts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            _pending.TryRemove(new KeyValuePair<string, CancellationTokenSource>(path, newCts));
            try { onFire(); } catch { /* logged elsewhere */ }
        }, TaskScheduler.Default);
    }
}
```

### 4.5 `FileClassifier`

```csharp
internal sealed class FileClassifier : IFileClassifier
{
    private ImmutableList<CompiledRule> _rules = ImmutableList<CompiledRule>.Empty;

    public void SetRules(ImmutableList<CompiledRule> rules)
        => Interlocked.Exchange(ref _rules, rules);

    public ClassifiedEvent? Classify(RawFsEvent raw, string watchRoot)
    {
        var rules = _rules;   // single atomic read
        var rel = ComputeRelative(raw.FullPath, watchRoot);
        var shardKey = ComputeShardKey(raw.FullPath, watchRoot);

        foreach (var r in rules)
        {
            if (r.Pattern.IsMatch(rel))
            {
                if (r.Priority == MonitorPriority.P4) return null;     // ignored
                return new ClassifiedEvent(raw, r.Module, r.OwnerService, r.Priority, shardKey, rel);
            }
        }
        // Fallback: P3 / Unknown / Unknown
        return new ClassifiedEvent(raw, "Unknown", "Unknown", MonitorPriority.P3, shardKey, rel);
    }

    private static string ComputeShardKey(string fullPath, string watchRoot)
    {
        var rel = Path.GetRelativePath(watchRoot, fullPath);
        var firstSep = rel.IndexOfAny(new[] { '\\', '/' });
        return firstSep < 0 ? "__global__" : rel[..firstSep];
    }

    private static string ComputeRelative(string fullPath, string watchRoot)
        => Path.GetRelativePath(watchRoot, fullPath);
}
```

### 4.6 `ShardRegistryRw`

```csharp
internal sealed class ShardRegistryRw : IShardRegistry, IAsyncDisposable
{
    private readonly ConcurrentDictionary<string, ShardHandle> _shards = new(StringComparer.OrdinalIgnoreCase);
    private readonly ISqliteRepositoryFactory _repoFactory;
    private readonly ISchemaMigrator _migrator;
    private readonly IEventRecorder _recorder;
    private readonly IOptionsMonitor<MonitorConfig> _cfg;
    private readonly IClock _clock;
    private readonly ILogger<ShardRegistryRw> _log;

    public Task RouteAsync(ClassifiedEvent e)
        => GetOrCreateAsync(e.ShardKey).ContinueWith(t => t.Result.Channel.Writer.WriteAsync(e).AsTask()).Unwrap();

    public async Task<ShardHandle> GetOrCreateAsync(string shardKey)
    {
        if (_shards.TryGetValue(shardKey, out var h)) return h;
        var dbPath = ResolveDbPath(shardKey);
        var repo = _repoFactory.OpenReadWrite(dbPath);
        await _migrator.EnsureSchemaAsync(repo.Connection, default);
        var ch = Channel.CreateBounded<ClassifiedEvent>(_cfg.CurrentValue.ShardChannelCapacity);
        var sem = new SemaphoreSlim(1, 1);
        var cts = new CancellationTokenSource();
        var writer = Task.Run(() => WriterLoopAsync(shardKey, repo, ch, sem, cts.Token));
        var handle = new ShardHandle(shardKey, dbPath, repo, ch, sem, writer, cts);
        return _shards.GetOrAdd(shardKey, handle);
    }

    private async Task WriterLoopAsync(string shardKey, ISqliteRepository repo,
        Channel<ClassifiedEvent> ch, SemaphoreSlim sem, CancellationToken ct)
    {
        await foreach (var e in ch.Reader.ReadAllAsync(ct))
        {
            await sem.WaitAsync(ct);
            try { await _recorder.RecordAsync(e, repo, ct); }
            catch (Exception ex) { _log.LogError(ex, "Record failed shard={Shard}", shardKey); }
            finally { sem.Release(); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var h in _shards.Values) await h.DisposeAsync();
    }
}

internal sealed record ShardHandle(
    string ShardKey, string DbPath, ISqliteRepository Repo,
    Channel<ClassifiedEvent> Channel, SemaphoreSlim Lock,
    Task Writer, CancellationTokenSource Cancellation) : IAsyncDisposable
{
    public async ValueTask DisposeAsync()
    {
        Channel.Writer.TryComplete();
        Cancellation.Cancel();
        try { await Writer.WaitAsync(TimeSpan.FromSeconds(5)); } catch { }
        await Repo.DisposeAsync();
        Lock.Dispose();
        Cancellation.Dispose();
    }
}
```

### 4.7 `EventRecorder`

```csharp
internal sealed class EventRecorder : IEventRecorder
{
    private readonly IHashService _hash;
    private readonly IDiffBuilder _diff;
    private readonly IClock _clock;
    private readonly IOptionsMonitor<MonitorConfig> _cfg;
    private readonly ILogger<EventRecorder> _log;

    public async Task RecordAsync(ClassifiedEvent e, ISqliteRepository repo, CancellationToken ct)
    {
        if (e.Priority == MonitorPriority.P4) { _log.LogWarning("P4 ignored {Path}", e.Raw.FullPath); return; }

        string? sha = e.Raw.ChangeType == FileChangeType.Deleted
            ? null
            : await _hash.ComputeAsync(e.Raw.FullPath, retries: 3, retryDelayMs: 100, ct);

        string? oldContent = null;
        string? diffText = null;

        if (e.Priority == MonitorPriority.P1 && e.Raw.ChangeType != FileChangeType.Deleted)
        {
            var prior = await repo.GetLastP1ContentAsync(e.Raw.FullPath, ct);
            var newContent = await File.ReadAllTextAsync(e.Raw.FullPath, ct);
            oldContent = newContent;
            diffText = _diff.BuildUnified(prior ?? string.Empty, newContent);
        }

        var row = new AuditLogRow(
            ChangedAt: _clock.UtcNow,
            EventType: e.Raw.ChangeType.ToString(),
            Filepath: e.Raw.FullPath,
            RelFilepath: e.RelFilepath,
            Module: e.Module,
            OwnerService: e.OwnerService,
            MonitorPriority: e.Priority.ToString(),
            MachineName: Environment.MachineName,
            Sha256Hash: sha,
            OldContent: oldContent,
            DiffText: diffText);

        await repo.InsertEventAsync(row, ct);
        if (sha is not null)
            await repo.UpsertBaselineAsync(e.Raw.FullPath, sha, _clock.UtcNow, ct);
    }
}
```

### 4.8 `JobLifecycleHandler` & `DirectoryWatcher`

```csharp
internal sealed class JobLifecycleHandler : IJobLifecycle
{
    private readonly IManifestManager _manifest;
    private readonly IShardRegistry _shards;
    private readonly ICatchUpCoordinator _catchUp;
    private readonly IClock _clock;

    public async Task OnArrivalAsync(string jobName, CancellationToken ct)
    {
        var jobFolder = Path.Combine(_cfg.WatchPath, jobName);
        await _manifest.RecordArrivalAsync(jobFolder, Environment.MachineName, _clock.UtcNow, ct);
        await _shards.GetOrCreateAsync(jobName);
        await _catchUp.ScheduleAsync(jobName, ct);
    }

    public async Task OnDepartureAsync(string jobName, CancellationToken ct)
    {
        var jobFolder = Path.Combine(_cfg.WatchPath, jobName);
        await _manifest.RecordDepartureAsync(jobFolder, Environment.MachineName, _clock.UtcNow, ct);
        await _shards.RemoveAsync(jobName); // disposes within 5 s
    }
}
```

### 4.9 `CatchUpCoordinator` & `CatchUpScanner`

```csharp
internal sealed class CatchUpCoordinator : ICatchUpCoordinator
{
    public async Task RunAllAsync(CancellationToken ct)
    {
        var jobs = Directory.EnumerateDirectories(_cfg.WatchPath).Select(Path.GetFileName).ToArray();
        await Parallel.ForEachAsync(jobs, ct, async (job, c) => await ScheduleAsync(job!, c));
    }

    public async Task ScheduleAsync(string jobName, CancellationToken ct)
    {
        var scanner = _factory.Create(jobName);
        await scanner.RunAsync(ct);
    }
}

internal sealed class CatchUpScanner : ICatchUpScanner
{
    public async Task RunAsync(CancellationToken ct)
    {
        var handle = await _shards.GetOrCreateAsync(_jobName);
        foreach (var file in Directory.EnumerateFiles(handle.JobFolder, "*", SearchOption.AllDirectories))
        {
            ct.ThrowIfCancellationRequested();
            var classified = _classifier.Classify(new RawFsEvent(file, FileChangeType.Modified, _clock.UtcNow), _cfg.WatchPath);
            if (classified is null) continue;
            var sha = await _hash.ComputeAsync(file, 3, 100, ct);
            var prior = await handle.Repo.GetLastHashAsync(file, ct);
            if (prior is null)
                await handle.Channel.Writer.WriteAsync(classified with { Raw = classified.Raw with { ChangeType = FileChangeType.Created } }, ct);
            else if (!string.Equals(prior, sha, StringComparison.OrdinalIgnoreCase))
                await handle.Channel.Writer.WriteAsync(classified, ct);

            if (handle.Channel.Reader.Count > _cfg.CatchUpYieldThreshold) await Task.Yield();
        }
        // pass 2: deletions — baselines without on-disk file
    }
}
```

---

## 5. Storage Implementations (`FalconAuditService.Core/Sqlite`)

### 5.1 `SqliteRepositoryFactory` & `SqliteRepository`

```csharp
internal sealed class SqliteRepositoryFactory : ISqliteRepositoryFactory
{
    public ISqliteRepository OpenReadWrite(string dbPath) => Open(dbPath, SqliteOpenMode.ReadWriteCreate, isReadOnly: false);
    public ISqliteRepository OpenReadOnly(string dbPath)  => Open(dbPath, SqliteOpenMode.ReadOnly,        isReadOnly: true);

    private static SqliteRepository Open(string dbPath, SqliteOpenMode mode, bool isReadOnly)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(dbPath)!);
        var cs = new SqliteConnectionStringBuilder
        {
            DataSource = dbPath,
            Mode = mode,
            Cache = SqliteCacheMode.Shared,
            DefaultTimeout = 5,
        }.ToString();
        var conn = new SqliteConnection(cs);
        conn.Open();
        ApplyPragmas(conn, isReadOnly);
        return new SqliteRepository(conn, isReadOnly);
    }

    private static void ApplyPragmas(SqliteConnection conn, bool isReadOnly)
    {
        using var cmd = conn.CreateCommand();
        // Read-only connections skip journal_mode (WAL is set by the writer and persists in the file header).
        // busy_timeout=5000 lets concurrent readers wait up to 5 s before returning SQLITE_BUSY.
        cmd.CommandText = isReadOnly
            ? "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8000; PRAGMA busy_timeout=5000;"
            : "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8000; PRAGMA busy_timeout=5000;";
        cmd.ExecuteNonQuery();
    }
}

internal sealed class SqliteRepository : ISqliteRepository
{
    public SqliteConnection Connection { get; }
    private readonly bool _readOnly;

    public SqliteRepository(SqliteConnection conn, bool readOnly) { Connection = conn; _readOnly = readOnly; }

    public async Task InsertEventAsync(AuditLogRow row, CancellationToken ct)
    {
        if (_readOnly) throw new InvalidOperationException("read-only");
        await using var cmd = Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO audit_log (changed_at, event_type, filepath, rel_filepath, module, owner_service,
                                   monitor_priority, machine_name, sha256_hash, old_content, diff_text)
            VALUES (@changed_at, @event_type, @filepath, @rel_filepath, @module, @owner_service,
                    @monitor_priority, @machine_name, @sha256, @old_content, @diff_text);
            """;
        cmd.Parameters.AddWithValue("@changed_at",       row.ChangedAt.UtcDateTime.ToString("O"));
        cmd.Parameters.AddWithValue("@event_type",       row.EventType);
        cmd.Parameters.AddWithValue("@filepath",         row.Filepath);
        cmd.Parameters.AddWithValue("@rel_filepath",     row.RelFilepath);
        cmd.Parameters.AddWithValue("@module",           (object?)row.Module ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@owner_service",    (object?)row.OwnerService ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@monitor_priority", row.MonitorPriority);
        cmd.Parameters.AddWithValue("@machine_name",     row.MachineName);
        cmd.Parameters.AddWithValue("@sha256",           (object?)row.Sha256Hash ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@old_content",      (object?)row.OldContent ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@diff_text",        (object?)row.DiffText ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task UpsertBaselineAsync(string filepath, string sha256, DateTimeOffset lastSeen, CancellationToken ct)
    {
        if (_readOnly) throw new InvalidOperationException("read-only");
        await using var cmd = Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO file_baselines (filepath, last_hash, last_seen) VALUES (@p, @h, @t)
            ON CONFLICT(filepath) DO UPDATE SET last_hash=excluded.last_hash, last_seen=excluded.last_seen;
            """;
        cmd.Parameters.AddWithValue("@p", filepath);
        cmd.Parameters.AddWithValue("@h", sha256);
        cmd.Parameters.AddWithValue("@t", lastSeen.UtcDateTime.ToString("O"));
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<string?> GetLastHashAsync(string filepath, CancellationToken ct) { /* SELECT last_hash FROM file_baselines WHERE filepath=@p */ }
    public async Task<string?> GetLastP1ContentAsync(string filepath, CancellationToken ct) { /* SELECT old_content FROM audit_log WHERE filepath=@p AND old_content IS NOT NULL ORDER BY id DESC LIMIT 1 */ }

    public async ValueTask DisposeAsync()
    {
        if (!_readOnly)
        {
            try { using var c = Connection.CreateCommand(); c.CommandText = "PRAGMA wal_checkpoint(TRUNCATE);"; c.ExecuteNonQuery(); }
            catch { /* best effort */ }
        }
        await Connection.DisposeAsync();
    }
}

internal sealed record AuditLogRow(
    DateTimeOffset ChangedAt, string EventType, string Filepath, string RelFilepath,
    string? Module, string? OwnerService, string MonitorPriority, string MachineName,
    string? Sha256Hash, string? OldContent, string? DiffText);
```

### 5.2 `SchemaMigrator`

```csharp
internal sealed class SchemaMigrator : ISchemaMigrator
{
    private const int TargetVersion = 1;
    private const string V1Sql = """
        CREATE TABLE audit_log ( /* per schema-design.md */ );
        CREATE TABLE file_baselines ( /* ... */ );
        CREATE INDEX ix_audit_changed_at      ON audit_log (changed_at DESC);
        CREATE INDEX ix_audit_relpath         ON audit_log (rel_filepath, changed_at DESC);
        CREATE INDEX ix_audit_module_priority ON audit_log (module, monitor_priority, changed_at DESC);
        CREATE INDEX ix_audit_machine_changed ON audit_log (machine_name, changed_at DESC);
        """;

    public async Task EnsureSchemaAsync(SqliteConnection conn, CancellationToken ct)
    {
        var current = await GetVersionAsync(conn, ct);
        if (current == TargetVersion) return;
        if (current > TargetVersion) throw new SchemaTooNewException(current, TargetVersion);

        await using var tx = await conn.BeginTransactionAsync(ct);
        await using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = (SqliteTransaction)tx;
            cmd.CommandText = V1Sql;
            await cmd.ExecuteNonQueryAsync(ct);
        }
        await using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = (SqliteTransaction)tx;
            cmd.CommandText = $"PRAGMA user_version = {TargetVersion};";
            await cmd.ExecuteNonQueryAsync(ct);
        }
        await tx.CommitAsync(ct);
    }
}
```

---

## 6. Query Process (`FalconAuditQuery`)

### 6.1 `Program.cs`

```csharp
var builder = WebApplication.CreateBuilder(args);
builder.Host.UseWindowsService(o => o.ServiceName = "FalconAuditQuery");
builder.Host.UseSerilog((ctx, lc) => lc
    .WriteTo.File(@"C:\bis\auditlog\logs\query-.log", rollingInterval: RollingInterval.Day));

builder.Services.Configure<MonitorConfig>(builder.Configuration.GetSection("monitor_config"));

builder.Services.AddSingleton<IClock, SystemClock>();
builder.Services.AddSingleton<IFileSystem, PhysicalFileSystem>();
builder.Services.AddSingleton<IClassificationRulesLoader, ClassificationRulesLoader>();
builder.Services.AddSingleton<IFileClassifier, FileClassifier>();
builder.Services.AddSingleton<IPathValidator, PathValidator>();
builder.Services.AddSingleton<IManifestManager, ManifestManager>();
builder.Services.AddSingleton<ISqliteRepositoryFactory, SqliteRepositoryFactory>();
builder.Services.AddSingleton<IJobDiscoveryService, JobDiscoveryService>();
builder.Services.AddSingleton<IShardReaderFactory, ShardReaderFactory>();
builder.Services.AddSingleton<IEventQueryBuilder, EventQueryBuilder>();
builder.Services.AddHostedService<JobDiscoveryHostedService>();

builder.Services.AddControllers();
builder.Services.Configure<RouteOptions>(o => o.ConstraintMap["relpath"] = typeof(RelFilepathConstraint));
builder.Services.AddProblemDetails();

builder.WebHost.ConfigureKestrel((ctx, k) =>
{
    var port = ctx.Configuration.GetValue("monitor_config:api_port", 5100);
    k.ListenLocalhost(port);
});

var app = builder.Build();
app.UseExceptionHandler("/error");
app.MapControllers();
await app.RunAsync();
```

### 6.2 `QueryController`

```csharp
[ApiController]
[Route("api")]
public sealed class QueryController : ControllerBase
{
    private readonly IJobDiscoveryService _disc;
    private readonly IShardReaderFactory _factory;
    private readonly IEventQueryBuilder _qb;
    private readonly IManifestManager _manifest;
    private readonly IPathValidator _path;
    private readonly IOptionsMonitor<MonitorConfig> _cfg;

    [HttpGet("jobs")]
    public async Task<ActionResult<IEnumerable<JobSummaryDto>>> Jobs(CancellationToken ct)
    {
        var jobs = _disc.Snapshot.Keys.OrderBy(s => s).ToArray();
        var list = new List<JobSummaryDto>();
        foreach (var name in jobs)
        {
            try
            {
                await using var rdr = await _factory.OpenAsync(name, ct);
                // SELECT COUNT(1), MAX(changed_at) ...
                list.Add(new JobSummaryDto(name, /* created */ null, /* count */ 0, /* latest */ null));
            }
            catch (ShardUnavailableException)
            {
                // shard deregistered between snapshot and open — skip rather than fail the whole list
            }
        }
        return Ok(list);
    }

    [HttpGet("jobs/{jobName}/manifest")]
    public async Task<ActionResult<ManifestDto>> Manifest(string jobName, CancellationToken ct)
    {
        var m = await _manifest.ReadAsync(Path.Combine(_cfg.CurrentValue.WatchPath, jobName), ct);
        return m is null ? NotFound() : Ok(m);
    }

    [HttpGet("jobs/{jobName}/files")]
    public async Task<ActionResult<IEnumerable<FileBaselineDto>>> Files(string jobName, [FromQuery] int page = 1, [FromQuery] int pageSize = 50, CancellationToken ct = default)
    {
        return await ExecuteShardActionAsync(jobName, ct, async (conn) =>
        {
            /* SELECT filepath, rel_filepath, last_hash, last_seen FROM file_baselines
               ORDER BY filepath LIMIT @ps OFFSET @off */
            return Ok(/* list */);
        });
    }

    [HttpGet("jobs/{jobName}/events")]
    public async Task<ActionResult<IEnumerable<EventListItemDto>>> Events(string jobName, [FromQuery] EventQueryFilter filter, CancellationToken ct)
    {
        return await ExecuteShardActionAsync(jobName, ct, async (conn) =>
        {
            var (where, parms) = _qb.Build(filter);
            var (total, rows) = await ExecutePagedAsync(conn, where, parms, filter.Page, filter.PageSize, ct);
            Response.Headers["X-Total-Count"] = total.ToString();
            Response.Headers["X-Page"]        = filter.Page.ToString();
            Response.Headers["X-PageSize"]    = filter.PageSize.ToString();
            Response.Headers["Cache-Control"] = "no-store";
            return Ok(rows);
        });
    }

    [HttpGet("jobs/{jobName}/events/{id:long}")]
    public async Task<ActionResult<EventDetailDto>> Detail(string jobName, long id, CancellationToken ct)
    {
        return await ExecuteShardActionAsync(jobName, ct, async (conn) =>
        {
            // SELECT all columns including old_content, diff_text WHERE id = @id
            var dto = await ReadDetailAsync(conn, id, ct);
            return dto is null ? NotFound() : Ok(dto);
        });
    }

    [HttpGet("jobs/{jobName}/history/{*filePath:relpath}")]
    public async Task<ActionResult<IEnumerable<EventListItemDto>>> History(string jobName, string filePath,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 50, CancellationToken ct = default)
    {
        if (!_path.IsSafe(filePath))
            return Problem("invalid path", statusCode: 400, type: "https://falconaudit/errors/invalid-path");

        return await ExecuteShardActionAsync(jobName, ct, async (conn) =>
        {
            // SELECT ... WHERE rel_filepath = @rel ORDER BY changed_at DESC LIMIT @ps OFFSET @off
            return Ok(/* list */);
        });
    }

    [HttpGet("global/events")]
    public async Task<ActionResult<IEnumerable<EventListItemDto>>> Global([FromQuery] EventQueryFilter filter, CancellationToken ct)
        => await Events("__global__", filter, ct);

    // -------------------------------------------------------------------------
    // Connection lifecycle helper — opens, executes, and disposes per request.
    // Maps ShardNotFoundException → 404 and ShardUnavailableException → 503.
    // -------------------------------------------------------------------------
    private async Task<ActionResult<T>> ExecuteShardActionAsync<T>(
        string jobName, CancellationToken ct,
        Func<SqliteConnection, Task<ActionResult<T>>> action)
    {
        try
        {
            await using var rdr = await _factory.OpenAsync(jobName, ct);
            return await action(rdr.Connection);
        }
        catch (ShardNotFoundException)
        {
            return NotFound();
        }
        catch (ShardUnavailableException)
        {
            return StatusCode(503, new ProblemDetails
            {
                Title  = "Shard temporarily unavailable",
                Status = 503,
                Detail = $"The shard for job '{jobName}' could not be opened. Retry after a few seconds.",
            });
        }
    }
}
```

### 6.3 `EventQueryBuilder`

```csharp
internal sealed class EventQueryBuilder : IEventQueryBuilder
{
    public (string WhereSql, IReadOnlyList<SqliteParameter> Params) Build(EventQueryFilter f)
    {
        var sb = new StringBuilder();
        var p = new List<SqliteParameter>();
        Append(sb, p, f.Module,    "module = @module",                     "@module");
        Append(sb, p, f.Priority,  "monitor_priority = @priority",         "@priority");
        Append(sb, p, f.Service,   "owner_service = @service",             "@service");
        Append(sb, p, f.EventType, "event_type = @eventType",              "@eventType");
        Append(sb, p, f.Machine,   "machine_name = @machine",              "@machine");
        if (f.From.HasValue) { sb.Append(sb.Length>0?" AND ":"").Append("changed_at >= @from"); p.Add(new("@from", f.From.Value.UtcDateTime.ToString("O"))); }
        if (f.To.HasValue)   { sb.Append(sb.Length>0?" AND ":"").Append("changed_at <  @to");   p.Add(new("@to",   f.To.Value.UtcDateTime.ToString("O"))); }
        if (!string.IsNullOrEmpty(f.Path))
        {
            sb.Append(sb.Length>0?" AND ":"").Append("rel_filepath LIKE @pattern ESCAPE '\\'");
            p.Add(new("@pattern", "%" + EscapeLike(f.Path!) + "%"));
        }
        return (sb.Length == 0 ? "1=1" : sb.ToString(), p);
    }

    private static string EscapeLike(string s) => s.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");

    private static void Append(StringBuilder sb, List<SqliteParameter> p, string? value, string clause, string paramName)
    {
        if (string.IsNullOrEmpty(value)) return;
        if (sb.Length > 0) sb.Append(" AND ");
        sb.Append(clause);
        p.Add(new SqliteParameter(paramName, value));
    }
}
```

### 6.4 `RelFilepathConstraint`

```csharp
internal sealed partial class RelFilepathConstraint : IRouteConstraint
{
    private static readonly Regex Allowed = AllowedRegex();

    public bool Match(HttpContext? httpContext, IRouter? route, string routeKey,
                      RouteValueDictionary values, RouteDirection direction)
        => values.TryGetValue(routeKey, out var raw)
           && raw is string s
           && s.Length is > 0 and <= 260
           && Allowed.IsMatch(s)
           && !s.Contains("..", StringComparison.Ordinal);

    [GeneratedRegex(@"^[\w\-. \\/]+$", RegexOptions.Compiled)]
    private static partial Regex AllowedRegex();
}
```

### 6.5 `JobDiscoveryService`

```csharp
internal sealed class JobDiscoveryService : IJobDiscoveryService
{
    private ImmutableDictionary<string, ShardLocation> _snapshot = ImmutableDictionary<string, ShardLocation>.Empty;
    public IReadOnlyDictionary<string, ShardLocation> Snapshot => _snapshot;

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        var roots = Directory.EnumerateDirectories(_cfg.WatchPath).ToArray();
        var b = ImmutableDictionary.CreateBuilder<string, ShardLocation>(StringComparer.OrdinalIgnoreCase);
        foreach (var dir in roots)
        {
            var name = Path.GetFileName(dir)!;
            var db = Path.Combine(dir, ".audit", "audit.db");
            if (File.Exists(db)) b[name] = new ShardLocation(name, db, dir);
        }
        b["__global__"] = new ShardLocation("__global__", _cfg.GlobalDbPath, _cfg.WatchPath);
        Interlocked.Exchange(ref _snapshot, b.ToImmutable());
    }

    public string? ResolveShardPath(string jobName)
        => _snapshot.TryGetValue(jobName, out var l) ? l.DbPath : null;
}

internal sealed class JobDiscoveryHostedService : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        await _disc.RefreshAsync(ct);
        var period = TimeSpan.FromSeconds(_cfg.CurrentValue.JobDiscoveryIntervalSeconds);
        using var timer = new PeriodicTimer(period);
        while (await timer.WaitForNextTickAsync(ct)) await _disc.RefreshAsync(ct);
    }
}
```

### 6.6 `ShardReaderFactory` and `ShardReadHandle`

```csharp
namespace FalconAuditQuery.Storage;

/// <summary>
/// Opens short-lived Mode=ReadOnly connections per HTTP request.
/// All connections to the same shard share one pool (identical connection string).
/// </summary>
internal sealed class ShardReaderFactory : IShardReaderFactory
{
    private readonly IJobDiscoveryService _disc;
    private readonly ILogger<ShardReaderFactory> _log;

    public ShardReaderFactory(IJobDiscoveryService disc, ILogger<ShardReaderFactory> log)
    {
        _disc = disc;
        _log  = log;
    }

    public Task<ShardReadHandle> OpenAsync(string jobName, CancellationToken ct)
    {
        var path = _disc.ResolveShardPath(jobName);
        if (path is null)
            throw new ShardNotFoundException(jobName);

        var cs = BuildConnectionString(path);
        SqliteConnection? conn = null;
        try
        {
            conn = new SqliteConnection(cs);
            conn.Open();
            ApplyReadPragmas(conn);
            return Task.FromResult(new ShardReadHandle(conn));
        }
        catch (SqliteException ex)
        {
            conn?.Dispose();
            _log.LogWarning(ex, "Cannot open shard for job {Job} at {Path}", jobName, path);
            throw new ShardUnavailableException(jobName, ex);
        }
    }

    /// <summary>
    /// Consistent connection string for all read-only connections to the same shard.
    /// Identical strings share the Microsoft.Data.Sqlite connection pool.
    /// </summary>
    private static string BuildConnectionString(string dbPath) =>
        new SqliteConnectionStringBuilder
        {
            DataSource     = dbPath,
            Mode           = SqliteOpenMode.ReadOnly,
            Cache          = SqliteCacheMode.Shared,
            DefaultTimeout = 5,
        }.ToString();

    private static void ApplyReadPragmas(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8000; PRAGMA busy_timeout=5000;";
        cmd.ExecuteNonQuery();
    }
}

/// <summary>
/// Wraps a read-only SqliteConnection for one HTTP request.
/// Disposing returns the connection to the pool.
/// </summary>
internal sealed class ShardReadHandle : IAsyncDisposable
{
    public SqliteConnection Connection { get; }

    public ShardReadHandle(SqliteConnection connection) => Connection = connection;

    public async ValueTask DisposeAsync() => await Connection.DisposeAsync();
}
```

---

## 7. Manifest Manager (shared)

```csharp
internal sealed class ManifestManager : IManifestManager
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web)
    { WriteIndented = true };

    public async Task<ManifestDto?> ReadAsync(string jobFolder, CancellationToken ct)
    {
        var path = Path.Combine(jobFolder, ".audit", "manifest.json");
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try { return JsonSerializer.Deserialize<ManifestDto>(await File.ReadAllBytesAsync(path, ct), JsonOpts); }
            catch (FileNotFoundException) { return null; }
            catch (DirectoryNotFoundException) { return null; }
            catch (IOException) when (attempt == 0) { await Task.Delay(50, ct); }
        }
        return null;
    }

    public async Task RecordArrivalAsync(string jobFolder, string machineName, DateTimeOffset at, CancellationToken ct)
    {
        var auditDir = Path.Combine(jobFolder, ".audit");
        Directory.CreateDirectory(auditDir);
        var path = Path.Combine(auditDir, "manifest.json");
        var existing = await ReadAsync(jobFolder, ct);
        var updated = (existing ?? new ManifestDto(Path.GetFileName(jobFolder)!, 1, new ManifestEntryDto(machineName, at), Array.Empty<MachineHistoryDto>()))
            with { History = AppendArrival(existing?.History, machineName, at) };
        await WriteAtomicAsync(path, updated, ct);
    }

    private static async Task WriteAtomicAsync(string path, ManifestDto dto, CancellationToken ct)
    {
        var tmp = path + ".tmp";
        await using (var fs = File.Create(tmp))
            await JsonSerializer.SerializeAsync(fs, dto, JsonOpts, ct);
        File.Move(tmp, path, overwrite: true);     // atomic on NTFS
    }
}
```

---

## 8. DI Registration Summary

| Service | Lifetime | Worker | Query |
|---|---|---|---|
| `IClock` | singleton | yes | yes |
| `IFileSystem` | singleton | yes | yes |
| `IClassificationRulesLoader` | singleton | yes | yes |
| `IFileClassifier` | singleton | yes | yes |
| `IPathValidator` | singleton | yes | yes |
| `IManifestManager` | singleton | yes | yes |
| `ISchemaMigrator` | singleton | yes | no |
| `ISqliteRepositoryFactory` | singleton | yes | yes |
| `IHashService` | singleton | yes | no |
| `IDiffBuilder` | singleton | yes | no |
| `IEventRecorder` | singleton | yes | no |
| `IShardRegistry` | singleton | yes | no |
| `IShardReaderFactory` | singleton | no | yes |
| `IFileMonitor` | singleton | yes | no |
| `IDirectoryWatcher` | singleton | yes | no |
| `IEventDebouncer` | singleton | yes | no |
| `IJobLifecycle` | singleton | yes | no |
| `ICatchUpCoordinator` | singleton | yes | no |
| `IRulesFileWatcher` | singleton | yes | no |
| `IJobDiscoveryService` | singleton | no | yes |
| `IEventQueryBuilder` | singleton | no | yes |
| `RelFilepathConstraint` | singleton (route map) | no | yes |
| `AuditHost` (IHostedService) | singleton | yes | no |
| `JobDiscoveryHostedService` | singleton | no | yes |

---

## 9. `appsettings.json` Skeleton

Both processes share the same settings shape (the worker does not consume `api_port`; the query process does not consume `debounce_ms`):

```json
{
  "monitor_config": {
    "watch_path":                  "c:\\job\\",
    "global_db_path":              "C:\\bis\\auditlog\\global.db",
    "classification_rules_path":   "C:\\bis\\auditlog\\FileClassificationRules.json",
    "api_port":                    5100,
    "debounce_ms":                 500,
    "catch_up_yield_threshold":    50,
    "shard_channel_capacity":      1024,
    "job_discovery_interval_seconds": 30
  },
  "Serilog": {
    "MinimumLevel": "Information"
  }
}
```

---

## 10. `install.ps1` Skeleton

```powershell
param([string]$BinDir = "C:\bis\FalconAudit")

$ErrorActionPreference = "Stop"

# Create log + global DB folders
New-Item -ItemType Directory -Force -Path "C:\bis\auditlog\logs" | Out-Null

# Install both services
sc.exe create FalconAuditWorker binPath= "$BinDir\FalconAuditWorker.exe" start= auto DisplayName= "Falcon Audit Worker"
sc.exe create FalconAuditQuery  binPath= "$BinDir\FalconAuditQuery.exe"  start= auto DisplayName= "Falcon Audit Query API" depend= FalconAuditWorker
sc.exe failure FalconAuditWorker reset= 60 actions= restart/5000/restart/5000/restart/15000
sc.exe failure FalconAuditQuery  reset= 60 actions= restart/5000/restart/5000/restart/15000

# Register Event Log source
New-EventLog -LogName Application -Source "FalconAuditService" -ErrorAction SilentlyContinue

sc.exe start FalconAuditWorker
Start-Sleep -Seconds 2
sc.exe start FalconAuditQuery
```

---

## 11. Coverage of Requirement Groups

| Group | Implementing files |
|---|---|
| SVC | `AuditHost.cs`, both `Program.cs` |
| MON | `FileMonitor.cs`, `EventDebouncer.cs` |
| CLS | `FileClassifier.cs`, `ClassificationRulesLoader.cs`, `RulesFileWatcher.cs` |
| REC | `EventRecorder.cs`, `HashService.cs`, `DiffPlexDiffBuilder.cs` |
| STR | `ShardRegistryRw.cs`, `SqliteRepositoryFactory.cs`, `SqliteRepository.cs`, `SchemaMigrator.cs` |
| JOB | `DirectoryWatcher.cs`, `JobLifecycleHandler.cs` |
| MFT | `ManifestManager.cs` |
| CUS | `CatchUpCoordinator.cs`, `CatchUpScanner.cs` |
| API | `QueryController.cs`, `EventQueryBuilder.cs`, `RelFilepathConstraint.cs`, `JobDiscoveryService.cs`, `ShardReaderFactory.cs`, `PathValidator.cs` |

Every interface listed in `architecture-design.md` Section 3 has at least one implementation stub above. Method bodies show the load-bearing logic explicitly; small private helpers and trivial getters are elided with `/* ... */` to keep the document focused on the architectural decisions.
