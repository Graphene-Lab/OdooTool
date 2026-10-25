using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIOrchestrator.API;

/// <summary>Query and manage Odoo ERP data: discover models and fields, search records,
/// create, update or delete records, call workflow actions, and read grouped aggregates.
/// Every operation runs as the configured Odoo user, so the ERP's own permissions apply.
/// Start with get_models() to discover what data is available, then get_fields() to learn
/// a model's structure before searching or writing.</summary>
[ToolPurpose(ToolPurpose.BusinessData)]
public class OdooTool : BaseAgentTool
{
    private static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(120) };

    // ─── Discovery ───────────────────────────────────────────────────────────────

    /// <summary>Lists every Odoo model the current user can access, with its technical name
    /// and human-readable description.</summary>
    /// <param name="filter">Optional substring to narrow results by name or description (case-insensitive).</param>
    /// <returns>JSON array of objects with "model" (technical name) and "name" (description).</returns>
    public string GetModels(string? filter = null)
    {
        Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(GetModels))} called, filter='{filter}'");

        var domain = new JsonArray();
        if (!string.IsNullOrWhiteSpace(filter))
        {
            domain = new JsonArray
            {
                JsonValue.Create("|")!,
                new JsonArray { JsonValue.Create("name")!, JsonValue.Create("ilike")!, JsonValue.Create($"%{filter}%")! },
                new JsonArray { JsonValue.Create("model")!, JsonValue.Create("ilike")!, JsonValue.Create($"%{filter}%")! }
            };
        }

        var body = new JsonObject
        {
            ["domain"] = domain,
            ["fields"] = new JsonArray { JsonValue.Create("model")!, JsonValue.Create("name")! },
            ["order"] = "model asc",
            ["limit"] = 500
        };

        var result = Call("POST", "ir.model/search_read", body, "get models");
        Log.LogStep($"{Utility.ToSnakeCase(nameof(GetModels))}: {result.Length} chars");
        return result;
    }

    /// <summary>Lists the fields of a given Odoo model: name, label, type, whether it is
    /// required, and what it relates to. Call get_models() first to find model names.</summary>
    /// <param name="model">Technical model name, e.g. "res.partner", "sale.order", "product.product".</param>
    /// <returns>JSON array of field objects: name, field_description (label), ttype (type), required, readonly, help, relation.</returns>
    public string GetFields(string model)
    {
        Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(GetFields))} called, model='{model}'");

        if (string.IsNullOrWhiteSpace(model))
            return "Error: 'model' is required. Use get_models() to find available model names.";

        var body = new JsonObject
        {
            ["domain"] = new JsonArray { new JsonArray { JsonValue.Create("model")!, JsonValue.Create("=")!, JsonValue.Create(model)! } },
            ["fields"] = new JsonArray { JsonValue.Create("name")!, JsonValue.Create("field_description")!, JsonValue.Create("ttype")!, JsonValue.Create("required")!, JsonValue.Create("readonly")!, JsonValue.Create("help")!, JsonValue.Create("relation")! },
            ["order"] = "name asc",
            ["limit"] = 500
        };

        var result = Call("POST", "ir.model.fields/search_read", body, $"get fields for '{model}'");
        Log.LogStep($"{Utility.ToSnakeCase(nameof(GetFields))}('{model}'): {result.Length} chars");
        return result;
    }

    // ─── Data Operations ─────────────────────────────────────────────────────────

    /// <summary>Searches records on a model using a domain filter and returns the requested
    /// fields. The domain is a JSON array of conditions like [["name","ilike","%Acme%"]].
    /// Supports operators: equals, not equals, ilike, like, in, not in, gt, lt, gte, lte, child_of, parent_of.</summary>
    /// <param name="model">Technical model name, e.g. "res.partner".</param>
    /// <param name="domain">JSON array of domain conditions, e.g. [["is_company","=",true]]. Use [] for all records.</param>
    /// <param name="fields">JSON array of field names to return, e.g. ["name","email","phone"]. Omit for default fields.</param>
    /// <param name="limit">Maximum number of records to return (default 80).</param>
    /// <param name="offset">Number of records to skip for pagination (default 0).</param>
    /// <param name="order">Sort order, e.g. "name asc" or "date_order desc".</param>
    /// <returns>JSON array of record objects with the requested fields.</returns>
    public string Search(string model, string domain = "[]", string? fields = null,
        int limit = 80, int offset = 0, string? order = null)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(Search))} called, model='{model}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required. Use get_models() to find available model names.";

            var body = new JsonObject
            {
                ["domain"] = ParseJson(domain, "domain"),
                ["limit"] = limit,
                ["offset"] = offset
            };
            if (!string.IsNullOrWhiteSpace(fields)) body["fields"] = ParseJson(fields, "fields");
            if (!string.IsNullOrWhiteSpace(order)) body["order"] = order;

            var result = Call("POST", $"{model}/search_read", body, $"search '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(Search))}('{model}'): {result.Length} chars");
            return result;
        });
    }

    /// <summary>Reads specific records by their IDs from a model, returning full field values.</summary>
    /// <param name="model">Technical model name, e.g. "res.partner".</param>
    /// <param name="ids">JSON array of record IDs to read, e.g. [1, 2, 3].</param>
    /// <param name="fields">JSON array of field names to return. Omit for all readable fields.</param>
    /// <returns>JSON array of record objects.</returns>
    public string Read(string model, string ids, string? fields = null)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(Read))} called, model='{model}', ids='{ids}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required.";
            if (string.IsNullOrWhiteSpace(ids))
                return "Error: 'ids' is required. Provide a JSON array of record IDs, e.g. [1, 2, 3].";

            var body = new JsonObject
            {
                ["ids"] = ParseJson(ids, "ids")
            };
            if (!string.IsNullOrWhiteSpace(fields)) body["fields"] = ParseJson(fields, "fields");

            var result = Call("POST", $"{model}/read", body, $"read '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(Read))}('{model}'): {result.Length} chars");
            return result;
        });
    }

    /// <summary>Creates a new record on a model with the given field values.
    /// Returns the ID of the newly created record.</summary>
    /// <param name="model">Technical model name, e.g. "res.partner".</param>
    /// <param name="values">JSON object of field values, e.g. {"name":"Acme Corp","email":"info@acme.com","is_company":true}.</param>
    /// <returns>The ID of the created record, or an error message.</returns>
    public string CreateRecord(string model, string values)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(CreateRecord))} called, model='{model}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required.";
            if (string.IsNullOrWhiteSpace(values))
                return "Error: 'values' is required. Provide a JSON object of field values.";

            var body = new JsonObject
            {
                ["vals_list"] = new JsonArray { ParseJson(values, "values") }
            };

            var result = Call("POST", $"{model}/create", body, $"create on '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(CreateRecord))}('{model}'): {result}");
            return result;
        });
    }

    /// <summary>Updates existing records on a model. Only the fields provided in 'values'
    /// are changed; all other fields remain untouched.</summary>
    /// <param name="model">Technical model name, e.g. "res.partner".</param>
    /// <param name="ids">JSON array of record IDs to update, e.g. [1, 2, 3].</param>
    /// <param name="values">JSON object of field values to set, e.g. {"email":"new@example.com"}.</param>
    /// <returns>JSON result of the update, or an error message.</returns>
    public string UpdateRecord(string model, string ids, string values)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(UpdateRecord))} called, model='{model}', ids='{ids}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required.";
            if (string.IsNullOrWhiteSpace(ids))
                return "Error: 'ids' is required. Provide a JSON array of record IDs.";
            if (string.IsNullOrWhiteSpace(values))
                return "Error: 'values' is required. Provide a JSON object of field values to update.";

            var body = new JsonObject
            {
                ["ids"] = ParseJson(ids, "ids"),
                ["vals"] = ParseJson(values, "values")
            };

            var result = Call("POST", $"{model}/write", body, $"update on '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(UpdateRecord))}('{model}'): {result}");
            return result;
        });
    }

    /// <summary>Deletes records from a model by their IDs. This is permanent and cannot be undone.</summary>
    /// <param name="model">Technical model name, e.g. "res.partner".</param>
    /// <param name="ids">JSON array of record IDs to delete, e.g. [1, 2, 3].</param>
    /// <returns>JSON result confirming deletion, or an error message.</returns>
    public string DeleteRecord(string model, string ids)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(DeleteRecord))} called, model='{model}', ids='{ids}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required.";
            if (string.IsNullOrWhiteSpace(ids))
                return "Error: 'ids' is required. Provide a JSON array of record IDs to delete.";

            var body = new JsonObject
            {
                ["ids"] = ParseJson(ids, "ids")
            };

            var result = Call("POST", $"{model}/unlink", body, $"delete from '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(DeleteRecord))}('{model}'): {result}");
            return result;
        });
    }

    /// <summary>Calls a workflow action on an Odoo model, such as confirming a sale order,
    /// cancelling a record, or posting an invoice. Use get_fields() to discover available
    /// actions on a model, or try common ones: action_confirm, action_cancel, action_post, action_done.</summary>
    /// <param name="model">Technical model name, e.g. "sale.order".</param>
    /// <param name="action">The action name to execute, e.g. "action_confirm", "action_cancel", "action_post".</param>
    /// <param name="ids">JSON array of record IDs to act on, e.g. [1]. Use [] for model-level actions.</param>
    /// <param name="params">Optional JSON object of additional parameters for the action.</param>
    /// <returns>JSON result from the action, or an error message.</returns>
    public string CallMethod(string model, string action, string ids = "[]", string? @params = null)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(CallMethod))} called, model='{model}', action='{action}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required.";
            if (string.IsNullOrWhiteSpace(action))
                return "Error: 'action' is required. Provide the action name, e.g. 'action_confirm'.";

            var body = new JsonObject();
            var idsNode = ParseJson(ids, "ids");
            if (idsNode is JsonArray arr && arr.Count > 0)
                body["ids"] = idsNode;
            if (!string.IsNullOrWhiteSpace(@params))
            {
                var paramsNode = ParseJson(@params, "params");
                if (paramsNode is JsonObject pObj)
                    foreach (var kvp in pObj)
                        body[kvp.Key] = kvp.Value?.DeepClone();
            }

            var result = Call("POST", $"{model}/{action}", body, $"call '{action}' on '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(CallMethod))}('{model}','{action}'): {result}");
            return result;
        });
    }

    /// <summary>Groups records by one or more fields and computes aggregates (sum, count, avg)
    /// over them. Useful for reports and statistics.</summary>
    /// <param name="model">Technical model name, e.g. "sale.order".</param>
    /// <param name="domain">JSON array of domain conditions to filter records before grouping.</param>
    /// <param name="groupBy">JSON array of field names to group by, e.g. ["partner_id","state"].</param>
    /// <param name="aggregates">JSON array of aggregate expressions, e.g. ["amount_total:sum","id:count"].</param>
    /// <param name="order">Sort order for the groups, e.g. "country_id asc". Omit for default.</param>
    /// <param name="limit">Maximum number of groups to return (default 80).</param>
    /// <returns>JSON array of group rows with the grouped values and aggregate results.</returns>
    public string ReadGroup(string model, string domain = "[]", string groupBy = "[]",
        string aggregates = "[]", string? order = null, int limit = 80)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(ReadGroup))} called, model='{model}'");

            if (string.IsNullOrWhiteSpace(model))
                return "Error: 'model' is required.";

            var body = new JsonObject
            {
                ["domain"] = ParseJson(domain, "domain"),
                ["groupby"] = ParseJson(groupBy, "groupBy"),
                ["aggregates"] = ParseJson(aggregates, "aggregates"),
                ["limit"] = limit
            };
            if (!string.IsNullOrWhiteSpace(order)) body["order"] = order;

            var result = Call("POST", $"{model}/read_group", body, $"read_group on '{model}'");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(ReadGroup))}('{model}'): {result.Length} chars");
            return result;
        });
    }

    // ─── Navigation / Menus ────────────────────────────────────────────────────────

    /// <summary>Lists the Odoo menus the current user can access, with their linked model
    /// and action. Useful to understand the application structure and find where data lives.</summary>
    /// <param name="filter">Optional substring to filter menu names (case-insensitive).</param>
    /// <returns>JSON array of menu items with id, name, parent_id.</returns>
    public string GetMenus(string? filter = null)
    {
        Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(GetMenus))} called, filter='{filter}'");

        var domain = new JsonArray();
        if (!string.IsNullOrWhiteSpace(filter))
        {
            domain = new JsonArray { JsonValue.Create("name")!, JsonValue.Create("ilike")!, JsonValue.Create($"%{filter}%")! };
        }

        var body = new JsonObject
        {
            ["domain"] = domain,
            ["fields"] = new JsonArray { JsonValue.Create("id")!, JsonValue.Create("name")!, JsonValue.Create("parent_id")! },
            ["order"] = "id asc",
            ["limit"] = 300
        };

        var result = Call("POST", "ir.ui.menu/search_read", body, "get menus");
        Log.LogStep($"{Utility.ToSnakeCase(nameof(GetMenus))}: {result.Length} chars");
        return result;
    }

    /// <summary>Returns detailed information about specific menus, including the linked
    /// action, domain filters, default groupings, and available view types.</summary>
    /// <param name="menuIds">JSON array of menu IDs to inspect, e.g. [45, 102].</param>
    /// <returns>JSON array of menu detail objects.</returns>
    public string GetMenuDetails(string menuIds)
    {
        return Guard(() =>
        {
            Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(GetMenuDetails))} called");

            if (string.IsNullOrWhiteSpace(menuIds))
                return "Error: 'menuIds' is required. Provide a JSON array of menu IDs.";

            var body = new JsonObject
            {
                ["ids"] = ParseJson(menuIds, "menuIds"),
                ["fields"] = new JsonArray { JsonValue.Create("name")!, JsonValue.Create("action")!, JsonValue.Create("parent_id")! }
            };

            var result = Call("POST", "ir.ui.menu/read", body, "get menu details");
            Log.LogStep($"{Utility.ToSnakeCase(nameof(GetMenuDetails))}: {result.Length} chars");
            return result;
        });
    }

    // ─── Context / Session ─────────────────────────────────────────────────────────

    /// <summary>Returns context about the currently authenticated Odoo user: active company,
    /// timezone, user name, and available companies.</summary>
    /// <returns>JSON object with user session context.</returns>
    public string GetContext()
    {
        Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(GetContext))} called");

        var body = new JsonObject { };
        var result = Call("POST", "res.users/context_get", body, "get context");
        Log.LogStep($"{Utility.ToSnakeCase(nameof(GetContext))}: {result.Length} chars");
        return result;
    }

    /// <summary>Checks the connection to the Odoo server and returns the server version.
    /// Use this to verify the tool is properly configured and can reach the ERP.</summary>
    /// <returns>JSON with version info on success, or an error describing what is wrong.</returns>
    public string CheckConnection()
    {
        Log.LogStep($"{nameof(OdooTool)}.{Utility.ToSnakeCase(nameof(CheckConnection))} called");

        OdooConfig.EnsureLoaded();
        if (!OdooConfig.IsConfigured)
            return "Error: Odoo is not configured. Set ODOO_BASE_URL and ODOO_API_KEY environment variables, or create PersistentData/odoo.json with {\"baseUrl\":\"...\",\"apiKey\":\"...\"}.";

        try
        {
            var url = $"{OdooConfig.BaseUrl}/web/version";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("User-Agent", "AgentBridge-OdooTool/1.0");
            var resp = Http.Send(req);
            var content = resp.Content.ReadAsStringAsync().Result;
            Log.LogStep($"{Utility.ToSnakeCase(nameof(CheckConnection))}: HTTP {(int)resp.StatusCode}");
            if (resp.IsSuccessStatusCode)
                return content;
            return $"Error: Server returned HTTP {(int)resp.StatusCode}. Check that the Odoo server is running.";
        }
        catch (Exception ex)
        {
            Log.LogStep($"{Utility.ToSnakeCase(nameof(CheckConnection))} FAILED: {ex.GetType().Name}");
            return "Error: Cannot reach the Odoo server. Check that ODOO_BASE_URL is correct and the server is running.";
        }
    }

    // ─── HTTP Plumbing ─────────────────────────────────────────────────────────────

    private static string Call(string httpMethod, string path, JsonObject? body, string what)
    {
        OdooConfig.EnsureLoaded();
        if (!OdooConfig.IsConfigured)
            return "Error: Odoo is not configured. Set ODOO_BASE_URL and ODOO_API_KEY environment variables, or create PersistentData/odoo.json with {\"baseUrl\":\"...\",\"apiKey\":\"...\"}.";

        try
        {
            var url = $"{OdooConfig.BaseUrl}/json/2/{path}";
            using var req = new HttpRequestMessage(new HttpMethod(httpMethod), url);
            req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {OdooConfig.ApiKey}");
            req.Headers.TryAddWithoutValidation("User-Agent", "AgentBridge-OdooTool/1.0");
            if (!string.IsNullOrWhiteSpace(OdooConfig.Database))
                req.Headers.TryAddWithoutValidation("X-Odoo-Database", OdooConfig.Database);
            if (body != null)
                req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

            var resp = Http.Send(req);
            var content = resp.Content.ReadAsStringAsync().Result;

            if (resp.IsSuccessStatusCode)
                return RenderData(content);

            return ExtractError(content, (int)resp.StatusCode);
        }
        catch (TaskCanceledException)
        {
            Log.LogStep($"OdooTool: TIMEOUT calling {what}");
            return $"Error: Request timed out while trying to {what}. The server may be overloaded or unreachable.";
        }
        catch (HttpRequestException ex)
        {
            Log.LogStep($"OdooTool: HTTP error calling {what}: {ex.GetType().Name}");
            return $"Error: Cannot reach the Odoo server while trying to {what}. Check the connection.";
        }
    }

    private static JsonNode? ParseJson(string json, string paramName)
    {
        try
        {
            return JsonNode.Parse(json);
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException($"Error: '{paramName}' is not valid JSON: {ex.Message}");
        }
    }

    /// <summary>Wraps a public method body to catch parse/validation exceptions and return them as Error: strings.</summary>
    private static string Guard(Func<string> body)
    {
        try { return body(); }
        catch (InvalidOperationException ex) when (ex.Message.StartsWith("Error:")) { return ex.Message; }
        catch (Exception ex) { return $"Error: {ex.Message}"; }
    }

    private static string RenderData(string content)
    {
        if (string.IsNullOrWhiteSpace(content)) return "null";
        try
        {
            var node = JsonNode.Parse(content);
            return node?.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) ?? "null";
        }
        catch
        {
            return content;
        }
    }

    private static string ExtractError(string content, int statusCode)
    {
        try
        {
            var node = JsonNode.Parse(content);
            var message = node?["message"]?.GetValue<string>()
                      ?? node?["error"]?["message"]?.GetValue<string>()
                      ?? node?["error"]?.GetValue<string>();
            if (!string.IsNullOrWhiteSpace(message))
                return $"Error (HTTP {statusCode}): {message}";
        }
        catch { }
        return $"Error: HTTP {statusCode}. The server rejected the request.";
    }
}
