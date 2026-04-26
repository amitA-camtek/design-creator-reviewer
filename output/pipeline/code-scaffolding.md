# FalconAuditService — Code Scaffolding

**Document ID:** SCA-FAU-001
**Date:** 2026-04-26
**Language:** C# 10, .NET 6 LTS
**Style:** nullable enabled, file-scoped namespaces, async/await throughout

This document gives **stubs only** — method bodies are intentionally elided (`throw new NotImplementedException()` or empty). Implementation is the next phase.

---

## 1. Solution layout

```
FalconAuditService.sln
src/
  FalconAuditService/                  (Worker project)
    FalconAuditService.csproj
    Program.cs
    appsettings.json
    Configuration/
      MonitorConfig.cs
    Hosting/
      FalconAuditWorker.cs
    Monitoring/
      FileMonitor.cs
      Debouncer.cs
      DirectoryWatcher.cs
    Classification/
      FileClassifier.cs
      ClassificationRulesLoader.cs
      CompiledRule.cs
      RawClassificationRule.cs
    Pipeline/
      EventPipeline.cs
      EventRecorder.cs
      ClassifiedEvent.cs
      RawFileEvent.cs
    Hashing/
      HashService.cs
    Diff/
      DiffService.cs
    Storage/
      ShardRegistry.cs
      SqliteRepository.cs
      GlobalRepository.cs
      AuditRow.cs
      BaselineRow.cs
    Manifest/
      ManifestManager.cs
      ManifestDocument.cs
    Lifecycle/
      JobManager.cs
      JobDiscoveryService.cs
    CatchUp/
      CatchUpScanner.cs
    Api/
      QueryHost.cs
      QueryEndpoints.cs
      Validators.cs
      Dtos/
        EventListItemDto.cs
        EventDetailDto.cs
        JobInfoDto.cs
    Logging/
      LoggingExtensions.cs
    install.ps1
tests/
  FalconAuditService.Tests/
    FalconAuditService.Tests.csproj
```

---

## 2. Project file (csproj)

```xml
<Project Sdk="Microsoft.NET.Sdk.Worker">
  <PropertyGroup>
    <TargetFramework>net6.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <UserSecretsId>falconauditservice</UserSecretsId>
    <RootNamespace>FalconAuditService</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.Hosting" Version="6.0.*" />
    <PackageReference Include="Microsoft.Extensions.Hosting.WindowsServices" Version="6.0.*" />
    <PackageReference Include="Microsoft.Data.Sqlite" Version="6.0.*" />
    <PackageReference Include="DiffPlex" Version="1.7.*" />
    <PackageReference Include="Serilog.Extensions.Hosting" Version="5.*" />
    <PackageReference Include="Serilog.Sinks.File" Version="5.*" />
    <PackageReference Include="Serilog.Sinks.EventLog" Version="3.*" />
    <PackageReference Include="Microsoft.AspNetCore.App" />     <!-- via FrameworkReference below -->
    <PackageReference Include="Swashbuckle.AspNetCore" Version="6.*" />
  </ItemGroup>
  <ItemGroup>
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
  </ItemGroup>
</Project>
```

---

## 3. Program.cs (composition root + DI)

```csharp
using FalconAuditService.Api;
using FalconAuditService.CatchUp;
using FalconAuditService.Classification;
using FalconAuditService.Configuration;
using FalconAuditService.Diff;
using FalconAuditService.Hashing;
using FalconAuditService.Hosting;
using FalconAuditService.Lifecycle;
using FalconAuditService.Manifest;
using FalconAuditService.Monitoring;
using FalconAuditService.Pipeline;
using FalconAuditService.Storage;
using Microsoft.Extensions.Caching.Memory;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseWindowsService(o => o.ServiceName = "FalconAuditService");
builder.Host.UseSerilog((ctx, lc) => lc.ReadFrom.Configuration(ctx.Configuration));

builder.Services.Configure<MonitorConfig>(builder.Configuration.GetSection("monitor_config"));
builder.Services.AddMemoryCache();

// Singletons (one per process)
builder.Services.AddSingleton<IClassificationRulesLoader, ClassificationRulesLoader>();
builder.Services.AddSingleton<IFileClassifier, FileClassifier>();
builder.Services.AddSingleton<IHashService, HashService>();
builder.Services.AddSingleton<IDiffService, DiffService>();
builder.Services.AddSingleton<IShardRegistry, ShardRegistry>();
builder.Services.AddSingleton<IGlobalRepository, GlobalRepository>();
builder.Services.AddSingleton<IManifestManager, ManifestManager>();
builder.Services.AddSingleton<IEventPipeline, EventPipeline>();
builder.Services.AddSingleton<IEventRecorder, EventRecorder>();
builder.Services.AddSingleton<IDebouncer, Debouncer>();
builder.Services.AddSingleton<IFileMonitor, FileMonitor>();
builder.Services.AddSingleton<IDirectoryWatcher, DirectoryWatcher>();
builder.Services.AddSingleton<ICatchUpScanner, CatchUpScanner>();
builder.Services.AddSingleton<IJobManager, JobManager>();
builder.Services.AddSingleton<IJobDiscoveryService, JobDiscoveryService>();

// The BackgroundService that orchestrates startup/shutdown
builder.Services.AddHostedService<FalconAuditWorker>();

// Kestrel binding (loopback only by default — API-009)
builder.WebHost.ConfigureKestrel((ctx, kestrel) =>
{
    var cfg = ctx.Configuration.GetSection("monitor_config").Get<MonitorConfig>()!;
    if (cfg.ApiBindLoopbackOnly)
        kestrel.ListenLocalhost(cfg.ApiPort);
    else
        kestrel.ListenAnyIP(cfg.ApiPort);
});

var app = builder.Build();
QueryEndpoints.Map(app);
await app.RunAsync();
```

---

## 4. Configuration

```csharp
namespace FalconAuditService.Configuration;

public sealed class MonitorConfig
{
    public string WatchPath { get; init; } = @"c:\job\";
    public string GlobalDbPath { get; init; } = @"C:\bis\auditlog\global.db";
    public string ClassificationRulesPath { get; init; } = @"C:\bis\auditlog\FileClassificationRules.json";
    public int ApiPort { get; init; } = 5100;
    public bool ApiBindLoopbackOnly { get; init; } = true;
    public int DebounceMs { get; init; } = 500;
    public int FswBufferSize { get; init; } = 65536;
    public int ContentSizeLimit { get; init; } = 1_048_576;
    public bool CaptureContent { get; init; } = true;
    public int ActiveJobRescanSeconds { get; init; } = 30;
    public int CatchupYieldThreshold { get; init; } = 50;
    public int CountCacheSeconds { get; init; } = 30;
}
```

---

## 5. Hosting

```csharp
namespace FalconAuditService.Hosting;

public sealed class FalconAuditWorker : BackgroundService
{
    private readonly IClassificationRulesLoader _rules;
    private readonly IFileMonitor _fileMonitor;
    private readonly IDirectoryWatcher _dirWatcher;
    private readonly IJobDiscoveryService _jobDiscovery;
    private readonly IJobManager _jobManager;
    private readonly ILogger<FalconAuditWorker> _log;

    public FalconAuditWorker(
        IClassificationRulesLoader rules,
        IFileMonitor fileMonitor,
        IDirectoryWatcher dirWatcher,
        IJobDiscoveryService jobDiscovery,
        IJobManager jobManager,
        ILogger<FalconAuditWorker> log)
    { /* assign */ throw new NotImplementedException(); }

    public override async Task StartAsync(CancellationToken ct) => throw new NotImplementedException();
    protected override async Task ExecuteAsync(CancellationToken ct) => throw new NotImplementedException();
    public override async Task StopAsync(CancellationToken ct) => throw new NotImplementedException();
}
```

---

## 6. Monitoring

```csharp
namespace FalconAuditService.Monitoring;

public interface IFileMonitor : IAsyncDisposable
{
    void Start();
    void Stop();
    event Action<RawFileEvent>? RawEventOccurred;
}

public sealed class FileMonitor : IFileMonitor
{
    private FileSystemWatcher? _fsw;
    private readonly IDebouncer _debouncer;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<FileMonitor> _log;

    public FileMonitor(IDebouncer debouncer, IOptions<MonitorConfig> cfg, ILogger<FileMonitor> log) => throw new NotImplementedException();

    public void Start() => throw new NotImplementedException();
    public void Stop() => throw new NotImplementedException();
    public event Action<RawFileEvent>? RawEventOccurred;
    public ValueTask DisposeAsync() => throw new NotImplementedException();

    private void OnChanged(object sender, FileSystemEventArgs e) => throw new NotImplementedException();
    private void OnRenamed(object sender, RenamedEventArgs e) => throw new NotImplementedException();
    private void OnError(object sender, ErrorEventArgs e) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Monitoring;

public interface IDebouncer
{
    void Push(RawFileEvent ev);
    int PendingCount { get; }
}

public sealed class Debouncer : IDebouncer
{
    private readonly ConcurrentDictionary<string, CancellationTokenSource> _timers = new();
    private readonly IFileClassifier _classifier;
    private readonly IEventPipeline _pipeline;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<Debouncer> _log;

    public Debouncer(IFileClassifier classifier, IEventPipeline pipeline, IOptions<MonitorConfig> cfg, ILogger<Debouncer> log) => throw new NotImplementedException();

    public int PendingCount => throw new NotImplementedException();
    public void Push(RawFileEvent ev) => throw new NotImplementedException();
    private async Task FireAfterDelayAsync(RawFileEvent ev, CancellationToken ct) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Monitoring;

public interface IDirectoryWatcher : IAsyncDisposable
{
    void Start();
    event Action<string>? JobArrived;
    event Action<string>? JobDeparted;
}

public sealed class DirectoryWatcher : IDirectoryWatcher
{
    public DirectoryWatcher(IOptions<MonitorConfig> cfg, ILogger<DirectoryWatcher> log) => throw new NotImplementedException();
    public void Start() => throw new NotImplementedException();
    public event Action<string>? JobArrived;
    public event Action<string>? JobDeparted;
    public ValueTask DisposeAsync() => throw new NotImplementedException();
}
```

---

## 7. Classification

```csharp
namespace FalconAuditService.Classification;

public sealed record CompiledRule(
    string PatternId,
    Regex Pattern,
    string Module,
    string OwnerService,
    int MonitorPriority,
    int Order);

public sealed record RawClassificationRule(
    string PatternId,
    string Glob,
    string Module,
    string OwnerService,
    int MonitorPriority);
```

```csharp
namespace FalconAuditService.Classification;

public interface IClassificationRulesLoader : IAsyncDisposable
{
    void LoadInitial();
    ImmutableList<CompiledRule> CurrentRules { get; }
    event Action? RulesReloaded;
}

public sealed class ClassificationRulesLoader : IClassificationRulesLoader
{
    private ImmutableList<CompiledRule> _rules = ImmutableList<CompiledRule>.Empty;
    private FileSystemWatcher? _rulesFsw;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<ClassificationRulesLoader> _log;

    public ClassificationRulesLoader(IOptions<MonitorConfig> cfg, ILogger<ClassificationRulesLoader> log) => throw new NotImplementedException();

    public ImmutableList<CompiledRule> CurrentRules => _rules;
    public event Action? RulesReloaded;
    public void LoadInitial() => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();

    private static Regex CompileGlob(string glob) => throw new NotImplementedException();
    private void OnRulesFileChanged(object sender, FileSystemEventArgs e) => throw new NotImplementedException();
    private void TryReload() => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Classification;

public interface IFileClassifier
{
    ClassifiedEvent Classify(RawFileEvent raw);
}

public sealed class FileClassifier : IFileClassifier
{
    private readonly IClassificationRulesLoader _loader;
    public FileClassifier(IClassificationRulesLoader loader) => throw new NotImplementedException();
    public ClassifiedEvent Classify(RawFileEvent raw) => throw new NotImplementedException();
}
```

---

## 8. Pipeline

```csharp
namespace FalconAuditService.Pipeline;

public sealed record RawFileEvent(
    DateTime ObservedAt,
    string Filepath,
    string? OldFilepath,
    EventType EventType);

public sealed record ClassifiedEvent(
    DateTime ObservedAt,
    string Filepath,
    string? OldFilepath,
    EventType EventType,
    string JobName,                    // "" for files directly under watch root (use global DB)
    string RelFilepath,
    string Module,
    string OwnerService,
    int MonitorPriority,
    string MatchedPatternId);

public enum EventType { Created, Modified, Deleted, Renamed, CustodyHandoff }
```

```csharp
namespace FalconAuditService.Pipeline;

public interface IEventPipeline : IAsyncDisposable
{
    Task WriteAsync(ClassifiedEvent ev, CancellationToken ct);
    int PendingCount { get; }
    Task DrainAsync(CancellationToken ct);
}

public sealed class EventPipeline : IEventPipeline
{
    private readonly Channel<ClassifiedEvent> _global;
    private readonly ConcurrentDictionary<string, Channel<ClassifiedEvent>> _shardChannels = new();
    private readonly ConcurrentDictionary<string, Task> _writerTasks = new();
    private readonly IEventRecorder _recorder;
    private readonly ILogger<EventPipeline> _log;

    public EventPipeline(IEventRecorder recorder, ILogger<EventPipeline> log) => throw new NotImplementedException();

    public int PendingCount => throw new NotImplementedException();
    public Task WriteAsync(ClassifiedEvent ev, CancellationToken ct) => throw new NotImplementedException();
    public Task DrainAsync(CancellationToken ct) => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();

    private Task FanOutLoopAsync(CancellationToken ct) => throw new NotImplementedException();
    private Channel<ClassifiedEvent> GetOrCreateShardChannel(string jobName) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Pipeline;

public interface IEventRecorder
{
    Task RecordAsync(ClassifiedEvent ev, CancellationToken ct);
}

public sealed class EventRecorder : IEventRecorder
{
    private readonly IShardRegistry _shards;
    private readonly IGlobalRepository _global;
    private readonly IHashService _hash;
    private readonly IDiffService _diff;
    private readonly IManifestManager _manifest;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<EventRecorder> _log;

    public EventRecorder(IShardRegistry shards, IGlobalRepository global, IHashService hash, IDiffService diff, IManifestManager manifest, IOptions<MonitorConfig> cfg, ILogger<EventRecorder> log) => throw new NotImplementedException();

    public Task RecordAsync(ClassifiedEvent ev, CancellationToken ct) => throw new NotImplementedException();
}
```

---

## 9. Hashing & Diff

```csharp
namespace FalconAuditService.Hashing;

public interface IHashService
{
    Task<string> ComputeWithRetryAsync(string filepath, int retries, int delayMs, CancellationToken ct);
}

public sealed class HashService : IHashService
{
    public Task<string> ComputeWithRetryAsync(string filepath, int retries, int delayMs, CancellationToken ct) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Diff;

public interface IDiffService
{
    string BuildUnifiedDiff(string oldContent, string newContent, string filepathHint);
}

public sealed class DiffService : IDiffService
{
    public string BuildUnifiedDiff(string oldContent, string newContent, string filepathHint) => throw new NotImplementedException();
}
```

---

## 10. Storage

```csharp
namespace FalconAuditService.Storage;

public sealed record AuditRow(
    DateTime ChangedAt,
    string EventType,
    string Filepath,
    string? OldFilepath,
    string RelFilepath,
    string Filename,
    string FileExtension,
    string Module,
    string OwnerService,
    int MonitorPriority,
    string? MatchedPatternId,
    string MachineName,
    string? OldHash,
    string? NewHash,
    string? Description,
    bool IsContentOmitted,
    string? OldContent,
    string? DiffText,
    bool CreatedByCatchup);

public sealed record BaselineRow(string Filepath, string LastHash, DateTime LastSeen, string? LastContent);
```

```csharp
namespace FalconAuditService.Storage;

public interface IShardRegistry : IAsyncDisposable
{
    SqliteRepository GetOrCreate(string jobName);
    Task DisposeShardAsync(string jobName, CancellationToken ct);
    bool TryGetShardPath(string jobName, out string path);
    IReadOnlyCollection<string> ActiveJobNames { get; }
}

public sealed class ShardRegistry : IShardRegistry
{
    private readonly ConcurrentDictionary<string, Lazy<SqliteRepository>> _shards = new();
    private readonly MonitorConfig _cfg;
    private readonly ILogger<ShardRegistry> _log;

    public ShardRegistry(IOptions<MonitorConfig> cfg, ILogger<ShardRegistry> log) => throw new NotImplementedException();

    public IReadOnlyCollection<string> ActiveJobNames => throw new NotImplementedException();
    public SqliteRepository GetOrCreate(string jobName) => throw new NotImplementedException();
    public Task DisposeShardAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public bool TryGetShardPath(string jobName, out string path) => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Storage;

public sealed class SqliteRepository : IAsyncDisposable
{
    private readonly SqliteConnection _writer;       // long-lived writer
    private readonly string _path;
    private readonly ILogger _log;

    public static async Task<SqliteRepository> OpenAsync(string path, ILogger log, CancellationToken ct) => throw new NotImplementedException();

    private SqliteRepository(string path, SqliteConnection writer, ILogger log) => throw new NotImplementedException();

    public string Path => _path;

    public Task AppendAuditRowAsync(AuditRow row, CancellationToken ct) => throw new NotImplementedException();
    public Task UpsertBaselineAsync(BaselineRow row, CancellationToken ct) => throw new NotImplementedException();
    public Task<BaselineRow?> GetBaselineAsync(string filepath, CancellationToken ct) => throw new NotImplementedException();
    public IAsyncEnumerable<BaselineRow> EnumerateBaselinesAsync(CancellationToken ct) => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();

    private static Task ApplyPragmasAsync(SqliteConnection cn, CancellationToken ct) => throw new NotImplementedException();
    private static Task EnsureSchemaAsync(SqliteConnection cn, CancellationToken ct) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Storage;

public interface IGlobalRepository
{
    Task AppendAuditRowAsync(AuditRow row, CancellationToken ct);
    Task UpsertBaselineAsync(BaselineRow row, CancellationToken ct);
    Task AppendCustodyEventAsync(string jobName, string eventKind, string machineName, string? priorMachine, string manifestPath, string? notes, CancellationToken ct);
}

public sealed class GlobalRepository : IGlobalRepository, IAsyncDisposable
{
    public GlobalRepository(IOptions<MonitorConfig> cfg, ILogger<GlobalRepository> log) => throw new NotImplementedException();
    public Task AppendAuditRowAsync(AuditRow row, CancellationToken ct) => throw new NotImplementedException();
    public Task UpsertBaselineAsync(BaselineRow row, CancellationToken ct) => throw new NotImplementedException();
    public Task AppendCustodyEventAsync(string jobName, string eventKind, string machineName, string? priorMachine, string manifestPath, string? notes, CancellationToken ct) => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();
}
```

---

## 11. Manifest

```csharp
namespace FalconAuditService.Manifest;

public sealed record ManifestDocument(
    string JobName,
    DateTime FirstObservedAt,
    string FirstObservedBy,
    DateTime LastEventAt,
    List<CustodyEntry> CustodyHistory);

public sealed record CustodyEntry(string MachineName, DateTime ArrivedAt, DateTime? DepartedAt, long EventCount);
```

```csharp
namespace FalconAuditService.Manifest;

public interface IManifestManager
{
    Task<ManifestDocument?> ReadAsync(string jobName, CancellationToken ct);
    Task RecordArrivalAsync(string jobName, CancellationToken ct);
    Task RecordDepartureAsync(string jobName, CancellationToken ct);
    Task OnEventRecordedAsync(string jobName, CancellationToken ct);
    Task FlushAsync(CancellationToken ct);
}

public sealed class ManifestManager : IManifestManager, IAsyncDisposable
{
    private readonly ConcurrentDictionary<string, ManifestDocument> _cache = new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _gates = new();
    private readonly MonitorConfig _cfg;
    private readonly ILogger<ManifestManager> _log;

    public ManifestManager(IOptions<MonitorConfig> cfg, ILogger<ManifestManager> log) => throw new NotImplementedException();

    public Task<ManifestDocument?> ReadAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public Task RecordArrivalAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public Task RecordDepartureAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public Task OnEventRecordedAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public Task FlushAsync(CancellationToken ct) => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();

    private static Task WriteAtomicAsync(string path, ManifestDocument doc, CancellationToken ct) => throw new NotImplementedException();
}
```

---

## 12. Lifecycle

```csharp
namespace FalconAuditService.Lifecycle;

public interface IJobManager
{
    Task EnumerateExistingAsync(CancellationToken ct);
    Task OnArrivalAsync(string jobName, CancellationToken ct);
    Task OnDepartureAsync(string jobName, CancellationToken ct);
}

public sealed class JobManager : IJobManager
{
    private readonly IDirectoryWatcher _dirWatcher;
    private readonly IShardRegistry _shards;
    private readonly IManifestManager _manifest;
    private readonly IGlobalRepository _global;
    private readonly ICatchUpScanner _catchUp;
    private readonly IJobDiscoveryService _discovery;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<JobManager> _log;

    public JobManager(IDirectoryWatcher dirWatcher, IShardRegistry shards, IManifestManager manifest, IGlobalRepository global, ICatchUpScanner catchUp, IJobDiscoveryService discovery, IOptions<MonitorConfig> cfg, ILogger<JobManager> log) => throw new NotImplementedException();

    public Task EnumerateExistingAsync(CancellationToken ct) => throw new NotImplementedException();
    public Task OnArrivalAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public Task OnDepartureAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Lifecycle;

public interface IJobDiscoveryService : IAsyncDisposable
{
    void Start();
    ImmutableList<JobInfo> CurrentJobs { get; }
    bool TryResolveShardPath(string jobName, out string path);
    void Refresh();
}

public sealed record JobInfo(string Name, string ShardPath, DateTime FirstObservedAt, DateTime LastEventAt, long EventCount, string MonitorMachine);

public sealed class JobDiscoveryService : IJobDiscoveryService
{
    private ImmutableList<JobInfo> _current = ImmutableList<JobInfo>.Empty;
    private FileSystemWatcher? _statusIniFsw;        // TODO-API-007-FAST
    private PeriodicTimer? _timer;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<JobDiscoveryService> _log;

    public JobDiscoveryService(IOptions<MonitorConfig> cfg, ILogger<JobDiscoveryService> log) => throw new NotImplementedException();

    public ImmutableList<JobInfo> CurrentJobs => _current;
    public void Start() => throw new NotImplementedException();
    public bool TryResolveShardPath(string jobName, out string path) => throw new NotImplementedException();
    public void Refresh() => throw new NotImplementedException();
    public ValueTask DisposeAsync() => throw new NotImplementedException();

    private Task RescanLoopAsync(CancellationToken ct) => throw new NotImplementedException();
}
```

---

## 13. Catch-up

```csharp
namespace FalconAuditService.CatchUp;

public interface ICatchUpScanner
{
    Task QueueJobAsync(string jobName, CancellationToken ct);
    Task ScanAllAsync(IEnumerable<string> jobNames, CancellationToken ct);
}

public sealed class CatchUpScanner : ICatchUpScanner
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly IShardRegistry _shards;
    private readonly IEventPipeline _pipeline;
    private readonly IHashService _hash;
    private readonly MonitorConfig _cfg;
    private readonly ILogger<CatchUpScanner> _log;

    public CatchUpScanner(IShardRegistry shards, IEventPipeline pipeline, IHashService hash, IOptions<MonitorConfig> cfg, ILogger<CatchUpScanner> log) => throw new NotImplementedException();

    public Task QueueJobAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    public Task ScanAllAsync(IEnumerable<string> jobNames, CancellationToken ct) => throw new NotImplementedException();

    private Task ScanJobAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
    private Task YieldIfBackedUpAsync(CancellationToken ct) => throw new NotImplementedException();
}
```

---

## 14. API

```csharp
namespace FalconAuditService.Api.Dtos;

public sealed record EventListItemDto(
    long Id, string Job, DateTime ChangedAt, string EventType,
    string Filepath, string RelFilepath, string Filename, string FileExtension,
    string Module, string OwnerService, int MonitorPriority, string MachineName,
    string? OldHash, string? NewHash, string? Description, bool IsContentOmitted);

public sealed record EventDetailDto(
    long Id, string Job, DateTime ChangedAt, string EventType,
    string Filepath, string? OldFilepath, string RelFilepath, string Filename, string FileExtension,
    string Module, string OwnerService, int MonitorPriority, string? MatchedPatternId, string MachineName,
    string? OldHash, string? NewHash, string? Description,
    bool IsContentOmitted, bool CreatedByCatchup,
    string? OldContent, string? DiffText);

public sealed record JobInfoDto(string Name, string ShardPath, DateTime FirstObservedAt, DateTime LastEventAt, long EventCount, string MonitorMachine);
```

```csharp
namespace FalconAuditService.Api;

internal static class Validators
{
    private static readonly Regex SafePath = new(@"^[\w\-. \\/]+$", RegexOptions.Compiled);
    private static readonly Regex SafeJobName = new(@"^[\w\-. ]+$", RegexOptions.Compiled);

    public static bool IsSafePath(string? value) => throw new NotImplementedException();
    public static bool IsSafeJobName(string? value) => throw new NotImplementedException();
    public static bool TryParseIso(string? value, out DateTime utc) => throw new NotImplementedException();
}
```

```csharp
namespace FalconAuditService.Api;

internal static class QueryEndpoints
{
    public static void Map(WebApplication app)
    {
        app.MapGet("/api/health", HealthAsync);
        app.MapGet("/api/jobs", ListJobsAsync);
        app.MapGet("/api/events", ListEventsAsync);
        app.MapGet("/api/events/{job}/{id:long}", GetEventAsync);
    }

    private static IResult HealthAsync(IJobDiscoveryService discovery) => throw new NotImplementedException();
    private static IResult ListJobsAsync(IJobDiscoveryService discovery) => throw new NotImplementedException();
    private static Task<IResult> ListEventsAsync(
        string? job, int? priority, string? path, string? from, string? to, string? event_type,
        int? limit, int? offset,
        IJobDiscoveryService discovery, IMemoryCache cache, IOptions<MonitorConfig> cfg) => throw new NotImplementedException();
    private static Task<IResult> GetEventAsync(string job, long id, IJobDiscoveryService discovery) => throw new NotImplementedException();
}
```

---

## 15. Tests project skeleton

```
tests/FalconAuditService.Tests/
  FalconAuditService.Tests.csproj
  Monitoring/
    DebouncerTests.cs
    FileMonitorTests.cs
  Classification/
    FileClassifierTests.cs
    ClassificationRulesLoaderTests.cs
  Pipeline/
    EventPipelineTests.cs
    EventRecorderTests.cs
  Storage/
    SqliteRepositoryTests.cs
    ShardRegistryTests.cs
  Manifest/
    ManifestManagerTests.cs
  Lifecycle/
    JobManagerTests.cs
    JobDiscoveryServiceTests.cs
  CatchUp/
    CatchUpScannerTests.cs
  Api/
    QueryEndpointsTests.cs
    ValidatorsTests.cs
  Integration/
    EndToEndTests.cs
    PerformanceTests.cs
  TestSupport/
    TempDir.cs
    FakeClock.cs
    InMemoryEventPipeline.cs
```

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net6.0</TargetFramework>
    <Nullable>enable</Nullable>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.*" />
    <PackageReference Include="xunit" Version="2.4.*" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.4.*" />
    <PackageReference Include="FluentAssertions" Version="6.*" />
    <PackageReference Include="Moq" Version="4.*" />
    <PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" Version="6.0.*" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\..\src\FalconAuditService\FalconAuditService.csproj" />
  </ItemGroup>
</Project>
```

---

## 16. Coverage map (component -> requirement groups)

| Class | Implements requirement group(s) |
|---|---|
| `FalconAuditWorker` | SVC |
| `FileMonitor`, `Debouncer`, `DirectoryWatcher` | MON, JOB-002 |
| `ClassificationRulesLoader`, `FileClassifier`, `CompiledRule` | CLS |
| `EventPipeline`, `EventRecorder`, `ClassifiedEvent`, `RawFileEvent` | REC, REL-001, REL-005, STR-005 |
| `HashService` | REC-009 |
| `DiffService` | REC-005 |
| `ShardRegistry`, `SqliteRepository`, `GlobalRepository`, `AuditRow` | STR |
| `ManifestManager`, `ManifestDocument` | STR-003, JOB-007, REL-003 |
| `JobManager`, `DirectoryWatcher`, `JobDiscoveryService` | JOB |
| `CatchUpScanner` | CUS, SVC-002, SVC-007, REL-002 |
| `QueryEndpoints`, `Validators`, `*Dto` | API, CON-005, CON-006 |
| `MonitorConfig`, `Program.cs`, `appsettings.json`, `install.ps1` | INS, CON-001..003, CON-004 (parameterised SQL is enforced in `SqliteRepository`) |
