// OdooTool test suite — 105 scenarios simulating real agent usage.
// Run: dotnet run --project OdooTool.Tests
// Tests input validation, error handling, and graceful degradation without a live Odoo server.
// With a live server, the "CheckNotCrash" tests would return real data instead of connection errors.

using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AIOrchestrator.API;

var passed = 0;
var failed = 0;
var results = new List<(string Name, bool Pass, string Detail)>();

void Check(string name, bool condition, string detail = "")
{
    if (condition) { passed++; results.Add((name, true, detail)); }
    else { failed++; results.Add((name, false, detail)); }
}

void CheckContains(string name, string actual, string expectedSubstring)
{
    var ok = actual.Contains(expectedSubstring, StringComparison.OrdinalIgnoreCase);
    Check(name, ok, ok ? "" : $"Expected to contain '{expectedSubstring}', got: {Truncate(actual, 200)}");
}

void CheckNotError(string name, string actual)
{
    Check(name, !actual.StartsWith("Error:"), actual.StartsWith("Error:") ? actual : "");
}

void CheckIsError(string name, string actual)
{
    Check(name, actual.StartsWith("Error:"), actual.StartsWith("Error:") ? "" : $"Expected error, got: {Truncate(actual, 200)}");
}

// For tests without a live server: the method should return a string (even a connection error)
// without throwing an unhandled exception.
void CheckNotCrash(string name, Func<string> fn)
{
    try
    {
        var result = fn();
        Check(name, result != null, result ?? "null");
    }
    catch (Exception ex)
    {
        Check(name, false, $"CRASH: {ex.GetType().Name}: {ex.Message}");
    }
}

string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "...";

Console.WriteLine("=== OdooTool Test Suite ===");
Console.WriteLine($"Started: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
Console.WriteLine("Mode: No live Odoo server — testing validation, error handling, and graceful degradation.");
Console.WriteLine();

// Configure with a non-routable address to avoid long timeouts
Environment.SetEnvironmentVariable("ODOO_BASE_URL", "http://127.0.0.1:19999");
Environment.SetEnvironmentVariable("ODOO_API_KEY", "test-key-12345");
Environment.SetEnvironmentVariable("ODOO_DATABASE", "testdb");
ResetConfig();

var tool = new OdooTool();

// ─── Phase 1: Configuration Tests (1-10) ────────────────────────────────────────

Console.WriteLine("--- Phase 1: Configuration ---");

// Test 1: No configuration - CheckConnection returns config error
Environment.SetEnvironmentVariable("ODOO_BASE_URL", null);
Environment.SetEnvironmentVariable("ODOO_API_KEY", null);
Environment.SetEnvironmentVariable("ODOO_DATABASE", null);
ResetConfig();
var r = tool.CheckConnection();
CheckIsError("T01: No config → CheckConnection error", r);
CheckContains("T01b: Error mentions ODOO_BASE_URL", r, "ODOO_BASE_URL");

// Test 2: Missing API key
Environment.SetEnvironmentVariable("ODOO_BASE_URL", "http://localhost:8069");
ResetConfig();
r = tool.CheckConnection();
CheckIsError("T02: Missing API key → error", r);

// Test 3: Empty base URL
Environment.SetEnvironmentVariable("ODOO_BASE_URL", "");
Environment.SetEnvironmentVariable("ODOO_API_KEY", "test-key");
ResetConfig();
r = tool.Search("res.partner");
CheckIsError("T03: Empty base URL → search error", r);

// Test 4: Config from env vars works
Environment.SetEnvironmentVariable("ODOO_BASE_URL", "http://127.0.0.1:19999");
Environment.SetEnvironmentVariable("ODOO_API_KEY", "test-api-key-123");
Environment.SetEnvironmentVariable("ODOO_DATABASE", "testdb");
ResetConfig();
Check("T04: Config loaded from env vars", OdooConfigIsConfigured());

// Test 5: Base URL trailing slash normalized
Environment.SetEnvironmentVariable("ODOO_BASE_URL", "http://127.0.0.1:19999///");
ResetConfig();
Check("T05: Trailing slashes trimmed", GetBaseUrl() == "http://127.0.0.1:19999");

// Test 6: Database optional
Environment.SetEnvironmentVariable("ODOO_DATABASE", null);
ResetConfig();
Check("T06: Database is optional (null ok)", OdooConfigIsConfigured());

// Test 7: Whitespace-only API key treated as missing
Environment.SetEnvironmentVariable("ODOO_API_KEY", "   ");
ResetConfig();
r = tool.GetModels();
CheckIsError("T07: Whitespace API key → error", r);

// Test 8: Very long API key accepted
Environment.SetEnvironmentVariable("ODOO_API_KEY", new string('a', 500));
ResetConfig();
Check("T08: Long API key accepted", OdooConfigIsConfigured());

// Test 9: Normal config after edge cases
Environment.SetEnvironmentVariable("ODOO_API_KEY", "valid-key");
ResetConfig();
Check("T09: Normal config restored", OdooConfigIsConfigured());

// Test 10: Config reload works
ResetConfig();
Check("T10: Config reload works", OdooConfigIsConfigured());

Console.WriteLine($"  Phase 1: {passed} passed, {failed} failed");
var p1 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 2: Input Validation Tests (11-30) ────────────────────────────────────

Console.WriteLine("--- Phase 2: Input Validation ---");

// These tests verify that invalid inputs return "Error:" BEFORE any HTTP call is made.
// They must NOT timeout or crash.

r = tool.Search("");
CheckIsError("T11: Empty model → error", r);

r = tool.Search(null!);
CheckIsError("T12: Null model → error", r);

r = tool.Search("res.partner", "{invalid json}");
CheckIsError("T13: Invalid JSON domain → error", r);

r = tool.Search("res.partner", "[]");
CheckNotCrash("T14: Empty domain [] valid (no crash)", () => tool.Search("res.partner", "[]"));

r = tool.Read("res.partner", "");
CheckIsError("T15: Read empty ids → error", r);

r = tool.Read("res.partner", "not-json");
CheckIsError("T16: Read invalid JSON ids → error", r);

r = tool.CreateRecord("res.partner", "");
CheckIsError("T17: Create empty values → error", r);

r = tool.CreateRecord("res.partner", "{broken");
CheckIsError("T18: Create invalid JSON → error", r);

r = tool.UpdateRecord("res.partner", "", "{\"name\":\"test\"}");
CheckIsError("T19: Update empty ids → error", r);

r = tool.UpdateRecord("res.partner", "[1]", "");
CheckIsError("T20: Update empty values → error", r);

r = tool.DeleteRecord("res.partner", "");
CheckIsError("T21: Delete empty ids → error", r);

r = tool.CallMethod("sale.order", "");
CheckIsError("T22: CallMethod empty action → error", r);

r = tool.CallMethod(null!, "action_confirm");
CheckIsError("T23: CallMethod null model → error", r);

r = tool.GetFields("");
CheckIsError("T24: GetFields empty model → error", r);

r = tool.GetMenuDetails("");
CheckIsError("T25: GetMenuDetails empty → error", r);

r = tool.Search("res.partner", "[]", limit: -1);
CheckNotCrash("T26: Negative limit doesn't crash", () => tool.Search("res.partner", "[]", limit: -1));

r = tool.Search("res.partner", "[]", limit: 100000);
CheckNotCrash("T27: Large limit doesn't crash", () => tool.Search("res.partner", "[]", limit: 100000));

r = tool.Search("res.partner", "[]", offset: -5);
CheckNotCrash("T28: Negative offset doesn't crash", () => tool.Search("res.partner", "[]", offset: -5));

r = tool.ReadGroup("sale.order", "[]", "[]", "[]");
CheckNotCrash("T29: ReadGroup empty groupBy doesn't crash", () => tool.ReadGroup("sale.order", "[]", "[]", "[]"));

r = tool.Search("res.partner.bank", "[]");
CheckNotCrash("T30: Dotted model name valid", () => tool.Search("res.partner.bank", "[]"));

Console.WriteLine($"  Phase 2: {passed} passed, {failed} failed");
var p2 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 3: Domain Format Tests (31-45) ───────────────────────────────────────

Console.WriteLine("--- Phase 3: Domain Formats ---");

CheckNotCrash("T31: Simple equality domain", () => tool.Search("res.partner", "[[\"name\",\"=\",\"Test\"]]"));
CheckNotCrash("T32: ilike domain", () => tool.Search("res.partner", "[[\"name\",\"ilike\",\"%test%\"]]"));
CheckNotCrash("T33: AND domain (multiple conditions)", () => tool.Search("res.partner", "[[\"is_company\",\"=\",true],[\"active\",\"=\",true]]"));
CheckNotCrash("T34: OR domain with |", () => tool.Search("res.partner", "[\"|\",[\"name\",\"=\",\"A\"],[\"name\",\"=\",\"B\"]]"));
CheckNotCrash("T35: NOT domain with !", () => tool.Search("res.partner", "[\"!\",[\"active\",\"=\",false]]"));
CheckNotCrash("T36: in operator", () => tool.Search("res.partner", "[[\"id\",\"in\",[1,2,3]]]"));
CheckNotCrash("T37: not in operator", () => tool.Search("res.partner", "[[\"id\",\"not in\",[1,2,3]]]"));
CheckNotCrash("T38: Numeric comparison", () => tool.Search("sale.order", "[[\"amount_total\",\">\",1000]]"));
CheckNotCrash("T39: Date domain", () => tool.Search("sale.order", "[[\"date_order\",\">=\",\"2026-01-01\"]]"));
CheckNotCrash("T40: Nested AND/OR", () => tool.Search("res.partner", "[\"&\",\"|\",[\"name\",\"=\",\"A\"],[\"name\",\"=\",\"B\"],[\"is_company\",\"=\",true]]"));
CheckNotCrash("T41: Empty array domain", () => tool.Search("res.partner", "[]"));
CheckNotCrash("T42: Domain with null value", () => tool.Search("res.partner", "[[\"parent_id\",\"=\",null]]"));
CheckNotCrash("T43: Unicode in domain", () => tool.Search("res.partner", "[[\"name\",\"ilike\",\"%caf%C3%A9%\"]]"));

var longDomain = new JsonArray();
for (int i = 0; i < 20; i++)
    longDomain.Add(new JsonArray { JsonValue.Create("field" + i)!, JsonValue.Create("=")!, JsonValue.Create(i)! });
CheckNotCrash("T44: Long domain (20 conditions)", () => tool.Search("res.partner", longDomain.ToJsonString()));

CheckNotCrash("T45: child_of operator", () => tool.Search("account.account", "[[\"parent_id\",\"child_of\",1]]"));

Console.WriteLine($"  Phase 3: {passed} passed, {failed} failed");
var p3 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 4: Fields Parameter Tests (46-55) ────────────────────────────────────

Console.WriteLine("--- Phase 4: Fields Parameter ---");

CheckNotCrash("T46: Fields as JSON array", () => tool.Search("res.partner", "[]", "[\"name\",\"email\",\"phone\"]"));
CheckNotCrash("T47: Empty fields array", () => tool.Search("res.partner", "[]", "[]"));
CheckNotCrash("T48: Null fields (default)", () => tool.Search("res.partner", "[]", null));
CheckIsError("T49: Invalid JSON fields → error", tool.Search("res.partner", "[]", "not-json"));
var manyFields = new JsonArray();
for (int i = 0; i < 50; i++) manyFields.Add(JsonValue.Create("field_" + i));
CheckNotCrash("T50: Many fields (50)", () => tool.Search("res.partner", "[]", manyFields.ToJsonString()));
CheckNotCrash("T51: Special field names", () => tool.Search("res.partner", "[]", "[\"x_custom_field\",\"__is_owner\"]"));
CheckNotCrash("T52: Dotted field path", () => tool.Search("sale.order.line", "[]", "[\"order_id.partner_id.name\"]"));
CheckNotCrash("T53: Read with specific fields", () => tool.Read("res.partner", "[1,2]", "[\"name\",\"email\"]"));
CheckNotCrash("T54: Read null fields", () => tool.Read("res.partner", "[1]", null));
CheckNotCrash("T55: Single field", () => tool.Search("res.partner", "[]", "[\"name\"]"));

Console.WriteLine($"  Phase 4: {passed} passed, {failed} failed");
var p4 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 5: CRUD Operations Tests (56-70) ─────────────────────────────────────

Console.WriteLine("--- Phase 5: CRUD Operations ---");

CheckNotCrash("T56: Create minimal", () => tool.CreateRecord("res.partner", "{\"name\":\"Test Partner\"}"));
CheckNotCrash("T57: Create many fields", () => tool.CreateRecord("res.partner", "{\"name\":\"Acme\",\"email\":\"a@b.com\",\"phone\":\"123\",\"is_company\":true}"));
CheckNotCrash("T58: Create with nested one2many", () => tool.CreateRecord("sale.order", "{\"partner_id\":1,\"order_line\":[[0,0,{\"product_id\":1,\"product_uom_qty\":2}]]}"));
CheckNotCrash("T59: Create with unicode", () => tool.CreateRecord("res.partner", "{\"name\":\"Café Ünïcode 日本語\"}"));
CheckNotCrash("T60: Create empty object", () => tool.CreateRecord("res.partner", "{}"));
CheckNotCrash("T61: Update single field", () => tool.UpdateRecord("res.partner", "[1]", "{\"name\":\"Updated Name\"}"));
CheckNotCrash("T62: Update multiple records", () => tool.UpdateRecord("res.partner", "[1,2,3]", "{\"active\":false}"));
CheckNotCrash("T63: Update many fields", () => tool.UpdateRecord("res.partner", "[1]", "{\"name\":\"X\",\"email\":\"x@y.com\",\"phone\":\"999\"}"));
CheckNotCrash("T64: Update with null (clear field)", () => tool.UpdateRecord("res.partner", "[1]", "{\"email\":null}"));
CheckNotCrash("T65: Update empty object", () => tool.UpdateRecord("res.partner", "[1]", "{}"));
CheckNotCrash("T66: Delete single", () => tool.DeleteRecord("res.partner", "[1]"));
CheckNotCrash("T67: Delete multiple", () => tool.DeleteRecord("res.partner", "[1,2,3,4,5]"));
CheckNotCrash("T68: Delete large ID", () => tool.DeleteRecord("res.partner", "[999999999]"));
CheckNotCrash("T69: Create with booleans", () => tool.CreateRecord("res.partner", "{\"name\":\"Test\",\"is_company\":true,\"active\":false}"));
CheckNotCrash("T70: Create with decimals", () => tool.CreateRecord("sale.order.line", "{\"product_uom_qty\":10.5,\"price_unit\":99.99}"));

Console.WriteLine($"  Phase 5: {passed} passed, {failed} failed");
var p5 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 6: Method Call Tests (71-82) ─────────────────────────────────────────

Console.WriteLine("--- Phase 6: Method Calls ---");

CheckNotCrash("T71: action_confirm", () => tool.CallMethod("sale.order", "action_confirm", "[1]"));
CheckNotCrash("T72: action_cancel", () => tool.CallMethod("sale.order", "action_cancel", "[1]"));
CheckNotCrash("T73: action_post (invoice)", () => tool.CallMethod("account.move", "action_post", "[1]"));
CheckNotCrash("T74: Model-level method (empty ids)", () => tool.CallMethod("res.users", "context_get", "[]"));
CheckNotCrash("T75: Method with params", () => tool.CallMethod("sale.order", "action_confirm", "[1]", "{\"pricelist_id\":1}"));
CheckNotCrash("T76: Method multiple ids", () => tool.CallMethod("sale.order", "action_confirm", "[1,2,3]"));
CheckNotCrash("T77: Non-existent method (server rejects)", () => tool.CallMethod("res.partner", "non_existent_method", "[1]"));
CheckIsError("T78: Invalid JSON params → error", tool.CallMethod("sale.order", "action_confirm", "[1]", "{invalid}"));
CheckNotCrash("T79: Null params OK", () => tool.CallMethod("sale.order", "action_confirm", "[1]", null));
CheckNotCrash("T80: Underscore method name", () => tool.CallMethod("sale.order", "action_confirm_order", "[1]"));
CheckNotCrash("T81: Descriptive method name", () => tool.CallMethod("res.partner", "get_partner_bank_accounts", "[1]"));
CheckNotCrash("T82: Many params", () => tool.CallMethod("sale.order", "action_confirm", "[1]", "{\"a\":1,\"b\":\"two\",\"c\":true,\"d\":null}"));

Console.WriteLine($"  Phase 6: {passed} passed, {failed} failed");
var p6 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 7: ReadGroup / Aggregation Tests (83-90) ─────────────────────────────

Console.WriteLine("--- Phase 7: Aggregation ---");

CheckNotCrash("T83: Group by state with sum", () => tool.ReadGroup("sale.order", "[]", "[\"state\"]", "[\"amount_total:sum\"]"));
CheckNotCrash("T84: Group by multiple fields", () => tool.ReadGroup("sale.order", "[]", "[\"partner_id\",\"state\"]", "[\"amount_total:sum\",\"id:count\"]"));
CheckNotCrash("T85: Group with filter", () => tool.ReadGroup("sale.order", "[[\"state\",\"=\",\"sale\"]]", "[\"partner_id\"]", "[\"amount_total:sum\"]"));
CheckNotCrash("T86: Group by month", () => tool.ReadGroup("sale.order", "[]", "[\"date_order:month\"]", "[\"amount_total:sum\"]"));
CheckNotCrash("T87: Count by country", () => tool.ReadGroup("res.partner", "[]", "[\"country_id\"]", "[\"id:count\"]"));
CheckNotCrash("T88: Avg and sum", () => tool.ReadGroup("sale.order.line", "[]", "[\"product_id\"]", "[\"price_unit:avg\",\"product_uom_qty:sum\"]"));
CheckNotCrash("T89: Group with limit", () => tool.ReadGroup("sale.order", "[]", "[\"state\"]", "[\"amount_total:sum\"]", limit: 5));
CheckNotCrash("T90: Group empty domain", () => tool.ReadGroup("res.partner", "[]", "[\"is_company\"]", "[\"id:count\"]"));

Console.WriteLine($"  Phase 7: {passed} passed, {failed} failed");
var p7 = (passed, failed); passed = 0; failed = 0;

// ─── Phase 8: Agent Confusion / Edge Cases (91-105) ──────────────────────────────

Console.WriteLine("--- Phase 8: Agent Confusion & Edge Cases ---");

CheckNotCrash("T91: Model with space (server rejects gracefully)", () => tool.Search("res partner", "[]"));
CheckNotCrash("T92: Domain as object instead of array", () => tool.Search("res.partner", "{\"name\":\"test\"}"));
CheckNotCrash("T93: Single id as number (not array)", () => tool.Read("res.partner", "1"));
CheckNotCrash("T94: Values as array instead of object", () => tool.CreateRecord("res.partner", "[\"name\",\"test\"]"));
CheckNotCrash("T95: Fields passed as domain", () => tool.Search("res.partner", "[\"name\",\"email\"]"));
CheckNotCrash("T96: Very long model name", () => tool.Search("a.very.long.model.name.that.goes.on", "[]"));
CheckNotCrash("T97: Model starting with number", () => tool.Search("123model", "[]"));
CheckNotCrash("T98: SQL injection attempt (safe via JSON)", () => tool.Search("res.partner", "[[\"name\",\"=\",\"'; DROP TABLE res_partner; --\"]]"));
CheckNotCrash("T99: XSS in values (safe via JSON)", () => tool.CreateRecord("res.partner", "{\"name\":\"<script>alert('xss')</script>\"}"));

var bigValues = new JsonObject();
for (int i = 0; i < 100; i++) bigValues["field_" + i] = new string('x', 100);
CheckNotCrash("T100: Large JSON payload (100 fields)", () => tool.CreateRecord("res.partner", bigValues.ToJsonString()));

CheckNotCrash("T101: 'method' in params (not a collision)", () => tool.CallMethod("sale.order", "action_confirm", "[1]", "{\"method\":\"bank\"}"));
CheckIsError("T102: Whitespace-only model → error", tool.Search("   ", "[]"));
CheckNotCrash("T103: Deeply nested domain", () => tool.Search("res.partner", "[[[[\"name\",\"=\",\"test\"]]]]"));
CheckNotCrash("T104: BOM in JSON domain", () => tool.Search("res.partner", "\uFEFF[]"));

// Test 105: Concurrent calls (thread safety)
var tasks = new List<Task<string>>();
for (int i = 0; i < 10; i++)
{
    var idx = i;
    tasks.Add(Task.Run(() => { try { return tool.Search("res.partner", $"[[\"id\",\"=\",{idx}]]"); } catch (Exception ex) { return $"CRASH:{ex.Message}"; } }));
}
Task.WaitAll(tasks.ToArray());
var noCrashes = tasks.All(t => !t.Result.StartsWith("CRASH:"));
Check("T105: 10 concurrent calls no crash", noCrashes);

Console.WriteLine($"  Phase 8: {passed} passed, {failed} failed");
var p8 = (passed, failed); passed = 0; failed = 0;

// ─── Summary ──────────────────────────────────────────────────────────────────────

Console.WriteLine();
Console.WriteLine("=== FINAL RESULTS ===");
var totalPassed = p1.Item1 + p2.Item1 + p3.Item1 + p4.Item1 + p5.Item1 + p6.Item1 + p7.Item1 + p8.Item1;
var totalFailed = p1.Item2 + p2.Item2 + p3.Item2 + p4.Item2 + p5.Item2 + p6.Item2 + p7.Item2 + p8.Item2;
Console.WriteLine($"Total: {totalPassed + totalFailed} tests");
Console.WriteLine($"Passed: {totalPassed}");
Console.WriteLine($"Failed: {totalFailed}");
Console.WriteLine($"Pass rate: {(totalPassed + totalFailed > 0 ? totalPassed * 100.0 / (totalPassed + totalFailed) : 0):F1}%");
Console.WriteLine();

if (totalFailed > 0)
{
    Console.WriteLine("Failed tests:");
    foreach (var fr in results.Where(x => !x.Pass))
        Console.WriteLine($"  FAIL: {fr.Name} — {fr.Detail}");
}

Console.WriteLine($"\nUnit tests completed: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");

// ─── Run 100 Business Scenario Tests ────────────────────────────────────────────
Console.WriteLine();
Console.WriteLine("═══════════════════════════════════════════");
Console.WriteLine("Running 100 Business Scenario Tests...");
Console.WriteLine("═══════════════════════════════════════════");
Console.WriteLine();
var bizResult = BusinessScenarios.Run();

var overallFail = totalFailed + bizResult;
Console.WriteLine();
Console.WriteLine("═══════════════════════════════════════════");
Console.WriteLine($"GRAND TOTAL: unit={totalPassed + totalFailed} + business=100 | failures={overallFail}");
Console.WriteLine($"Overall pass rate: {((totalPassed + totalFailed + 100 - overallFail) * 100.0 / (totalPassed + totalFailed + 100)):F1}%");
Console.WriteLine($"Completed: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
return overallFail > 0 ? 1 : 0;

// ─── Helpers ──────────────────────────────────────────────────────────────────────

void ResetConfig()
{
    var configType = typeof(OdooTool).Assembly.GetType("AIOrchestrator.API.OdooConfig");
    if (configType != null)
    {
        var loadedField = configType.GetField("_loaded", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
        loadedField?.SetValue(null, false);
    }
}

void EnsureConfigLoaded()
{
    var configType = typeof(OdooTool).Assembly.GetType("AIOrchestrator.API.OdooConfig");
    var method = configType?.GetMethod("EnsureLoaded", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic);
    method?.Invoke(null, null);
}

bool OdooConfigIsConfigured()
{
    EnsureConfigLoaded();
    var configType = typeof(OdooTool).Assembly.GetType("AIOrchestrator.API.OdooConfig");
    var prop = configType?.GetProperty("IsConfigured", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic);
    return (bool)(prop?.GetValue(null) ?? false);
}

string GetBaseUrl()
{
    EnsureConfigLoaded();
    var configType = typeof(OdooTool).Assembly.GetType("AIOrchestrator.API.OdooConfig");
    var prop = configType?.GetProperty("BaseUrl", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic);
    return (string?)(prop?.GetValue(null)) ?? "";
}
