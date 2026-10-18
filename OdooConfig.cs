using System.Text.Json;

namespace AIOrchestrator.API;

/// <summary>
/// Connection settings for the Odoo instance the tool drives. Resolved from environment
/// variables (ODOO_BASE_URL / ODOO_API_KEY / ODOO_DATABASE) or, as a fallback, from
/// <c>PersistentData/odoo.json</c> in the host's base directory.
/// </summary>
internal static class OdooConfig
{
    public static string? BaseUrl { get; private set; }
    public static string? ApiKey { get; private set; }
    public static string? Database { get; private set; }

    private static bool _loaded;

    public static void EnsureLoaded()
    {
        if (_loaded) return;
        _loaded = true;

        BaseUrl = Environment.GetEnvironmentVariable("ODOO_BASE_URL");
        ApiKey = Environment.GetEnvironmentVariable("ODOO_API_KEY");
        Database = Environment.GetEnvironmentVariable("ODOO_DATABASE");

        if (string.IsNullOrWhiteSpace(BaseUrl) || string.IsNullOrWhiteSpace(ApiKey))
        {
            try
            {
                var file = Path.Combine(AppContext.BaseDirectory, "PersistentData", "odoo.json");
                if (File.Exists(file))
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(file));
                    var root = doc.RootElement;
                    if (string.IsNullOrWhiteSpace(BaseUrl) && root.TryGetProperty("baseUrl", out var b)) BaseUrl = b.GetString();
                    if (string.IsNullOrWhiteSpace(ApiKey) && root.TryGetProperty("apiKey", out var k)) ApiKey = k.GetString();
                    if (string.IsNullOrWhiteSpace(Database) && root.TryGetProperty("database", out var d)) Database = d.GetString();
                }
            }
            catch { /* best-effort; missing values surface as a clear tool error */ }
        }

        BaseUrl = BaseUrl?.TrimEnd('/');
    }

    public static bool IsConfigured =>
        !string.IsNullOrWhiteSpace(BaseUrl) && !string.IsNullOrWhiteSpace(ApiKey);
}
