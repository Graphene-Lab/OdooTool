using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using AIOrchestrator;
using AIOrchestrator.API;

namespace OdooTool.AgentTests;

/// <summary>
/// Agent-driven test campaign: every scenario is given to the REAL LLM agent as a natural
/// language prompt; the agent must use OdooTool to accomplish it. Each run is verified against
/// Odoo (JSON-2), its log slice is captured, and a minimal report is written.
/// </summary>
public static class Program
{
    private const string BaseUrl = "http://localhost:8069";
    private const string Database = "odoo_agent";
    // The key belongs to the throwaway test database and comes from the environment: a
    // credential must not live in the repository, which is public.
    private static readonly string ApiKey = Environment.GetEnvironmentVariable("ODOO_API_KEY") ?? string.Empty;
    private const string Provider = "LanLLM";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };

    public static async Task<int> Main(string[] args)
    {
        // Verifies that AgentBridge's plugin host really loads a plugin from a Tools/ folder:
        // OdooTool.AgentTests --plugin-check <toolsDir>
        if (args.Length == 2 && args[0] == "--plugin-check")
        {
            foreach (var d in Directory.GetFiles(args[1], "*.dll", SearchOption.AllDirectories))
            {
                try
                {
                    var asm = System.Reflection.Assembly.LoadFrom(d);
                    Console.WriteLine($"LOADED {Path.GetFileName(d)} -> {asm.GetName().Name}");
                    foreach (var t in asm.GetTypes())
                        if (typeof(BaseAgentTool).IsAssignableFrom(t) && !t.IsAbstract)
                            Console.WriteLine($"  TOOL {t.FullName}");
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"FAIL {Path.GetFileName(d)}: {ex.GetType().Name}: {ex.Message}");
                    if (ex.InnerException != null) Console.WriteLine($"  INNER: {ex.InnerException.Message}");
                }
            }
            using var host = new McpToolHost(args[1], watch: false);
            Console.WriteLine("TOOLS=" + string.Join(",", host.ToolNames));
            return host.ToolNames.Contains("OdooTool") ? 0 : 1;
        }

        // Accepts single ids ("5 7") and ranges ("101-200").
        var only = args.Length > 0
            ? args.SelectMany(a => a.Contains('-')
                    ? Enumerable.Range(int.Parse(a.Split('-')[0]), int.Parse(a.Split('-')[1]) - int.Parse(a.Split('-')[0]) + 1)
                    : new[] { int.Parse(a) })
                .ToHashSet()
            : null;

        if (string.IsNullOrEmpty(ApiKey))
        {
            Console.Error.WriteLine("ODOO_API_KEY is not set: export the key of the throwaway test database before running the campaign.");
            return 2;
        }

        // LLM provider configuration (keys live in AgentBridge's PersistentData).
        ProviderConfigs.ConfigDirectory = @"C:\Users\andre\OneDrive\Sorgenti\AgentBridge\bin\Debug\net10.0\PersistentData";

        // OdooTool connection settings.
        Environment.SetEnvironmentVariable("ODOO_BASE_URL", BaseUrl);
        Environment.SetEnvironmentVariable("ODOO_API_KEY", ApiKey);
        Environment.SetEnvironmentVariable("ODOO_DATABASE", Database);

        Log.IsEnabled = true;
        McpToolRegistry.Register(typeof(AIOrchestrator.API.OdooTool));

        Console.WriteLine($"=== OdooTool Agent Campaign — provider {Provider}, db {Database} ===");
        var reportName = Environment.GetEnvironmentVariable("ODOO_TEST_REPORT");
        var reportPath = Path.Combine(AppContext.BaseDirectory, string.IsNullOrWhiteSpace(reportName) ? "agent-report.md" : reportName);
        await File.WriteAllTextAsync(reportPath,
            $"# OdooTool — Agent Test Report\n\nProvider: **{Provider}** · DB: **{Database}** · Started: {DateTime.Now:yyyy-MM-dd HH:mm}\n\n");

        var results = new List<(Scenario S, bool Pass, string Methods, string Notes, string Answer)>();
        var total = 0; var passed = 0;

        foreach (var s in Scenarios.All.Concat(ScenariosBatch2.All).Concat(ScenariosBatch3.All))
        {
            if (only != null && !only.Contains(s.Id)) continue;
            total++;
            Console.WriteLine($"\n--- [{s.Id}] {s.Area}: {s.Prompt}");
            var logBefore = SnapshotLog();

            AgentResult result;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                using var harness = new AgentHarness(Provider);
                result = harness.ExecuteAction(s.Prompt, ["OdooTool"], maxIterations: 20);
            }
            catch (Exception ex)
            {
                result = new AgentResult { Code = AgentResultCode.NoLlmResponse, Error = ex.Message };
            }
            sw.Stop();

            var newLog = ReadNewLog(logBefore);
            var methods = ExtractMethods(newLog);
            var toolErrors = CountToolErrors(newLog);

            var (ok, why) = await VerifyAsync(s, result, newLog, toolErrors);
            if (ok) passed++;

            var answer = Truncate(result.Message ?? result.Error ?? $"({result.Code}/{result.FailureReason})", 400);
            Console.WriteLine($"    → {(ok ? "PASS" : "FAIL")} ({sw.Elapsed.TotalSeconds:F0}s) methods=[{methods}] {why}");
            Console.WriteLine($"    answer: {Truncate(answer, 200)}");

            results.Add((s, ok, methods, why, answer));
            await File.AppendAllTextAsync(reportPath,
                $"## [{s.Id}] {s.Area} — {(ok ? "PASS" : "FAIL")}\n\n" +
                $"**Prompt:** {s.Prompt}\n\n" +
                $"**Metodi OdooTool usati:** {methods}\n\n" +
                $"**Esito verifica:** {why}\n\n" +
                $"**Risposta agente:** {answer}\n\n");
        }

        await File.AppendAllTextAsync(reportPath,
            $"\n---\n\n**TOTALE: {passed}/{total} PASS** · {DateTime.Now:yyyy-MM-dd HH:mm}\n");

        Console.WriteLine($"\n=== TOTALE: {passed}/{total} PASS — report: {reportPath} ===");
        return passed == total ? 0 : 1;
    }

    private static async Task<(bool ok, string why)> VerifyAsync(Scenario s, AgentResult result, string log, int toolErrors)
    {
        if (result.Code != AgentResultCode.Success || result.Error != null)
            return (false, $"agent error: {result.Code}/{result.FailureReason} {Truncate(result.Error ?? "", 120)}");

        if (s.VerifyModel is null)
        {
            // Read-only/report scenario: the agent must have called OdooTool and produced an answer.
            var called = log.Contains("OdooTool.", StringComparison.Ordinal);
            var answered = !string.IsNullOrWhiteSpace(result.Message);
            return (called && answered && toolErrors == 0,
                called ? (answered ? "read-only OK" : "empty answer") : "OdooTool not called");
        }

        var count = await CountAsync(s.VerifyModel, s.VerifyDomain ?? "[]");
        return (count >= s.ExpectMin,
            count >= s.ExpectMin ? $"verified {count} record(s) in {s.VerifyModel}" : $"verification failed: 0 records in {s.VerifyModel}");
    }

    private static async Task<int> CountAsync(string model, string domain)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, $"{BaseUrl}/json/2/{model}/search_read");
            req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {ApiKey}");
            if (!string.IsNullOrWhiteSpace(Database)) req.Headers.TryAddWithoutValidation("X-Odoo-Database", Database);
            req.Content = new StringContent($$"""{"domain":{{domain}},"fields":["id"],"limit":5}""", Encoding.UTF8, "application/json");
            var resp = await Http.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode) return 0;
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.GetArrayLength();
        }
        catch { return 0; }
    }

    private static (string? file, long length) SnapshotLog()
    {
        var f = Log.CurrentLogFile;
        if (f is null || !File.Exists(f)) return (null, 0);
        return (f, new FileInfo(f).Length);
    }

    private static string ReadNewLog((string? file, long length) before)
    {
        var f = Log.CurrentLogFile;
        if (f is null || !File.Exists(f)) return "";
        try
        {
            using var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            if (before.file == f && fs.Length > before.length)
            {
                fs.Seek(before.length, SeekOrigin.Begin);
                using var sr = new StreamReader(fs);
                return sr.ReadToEnd();
            }
            fs.Seek(0, SeekOrigin.Begin);
            using var sr2 = new StreamReader(fs);
            return sr2.ReadToEnd();
        }
        catch { return ""; }
    }

    private static string ExtractMethods(string log)
    {
        var set = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var line in log.Split('\n'))
        {
            if (line.StartsWith("Log file created:", StringComparison.Ordinal)) continue;
            var idx = line.IndexOf("OdooTool.", StringComparison.Ordinal);
            if (idx < 0) continue;
            var rest = line[(idx + "OdooTool.".Length)..];
            var end = rest.IndexOfAny([' ', '(', ':', '\r']);
            if (end > 0) set.Add(rest[..end]);
        }
        return set.Count > 0 ? string.Join(", ", set) : "(none)";
    }

    private static int CountToolErrors(string log) =>
        log.Split('\n').Count(l => l.Contains("Error:", StringComparison.OrdinalIgnoreCase) && l.Contains("OdooTool", StringComparison.Ordinal));

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";
}
