namespace LiveCopilot.Core;

public enum ServiceHTTPFailureKind { Authentication, Billing, Permission, Model, Parameters, RateLimit, Service }
public static class ServiceHTTPFailureKindExtensions
{
    public static string Message(this ServiceHTTPFailureKind kind) => kind switch
    {
        ServiceHTTPFailureKind.Authentication => "API key rejected. It may be invalid, expired or revoked. Replace it with a key for this provider and region.",
        ServiceHTTPFailureKind.Billing => "API balance or usage limit reached. Check whether the account needs a top-up, credits have expired, or a spending limit was reached.",
        ServiceHTTPFailureKind.Permission => "Service access denied. Check model permissions and regional availability.",
        ServiceHTTPFailureKind.Model => "Model or endpoint unavailable. Check the model ID and service address.",
        ServiceHTTPFailureKind.Parameters => "Service rejected the request. Check model name and supported configuration.",
        ServiceHTTPFailureKind.RateLimit => "Request frequency or quota limit reached. Retry later; if it persists, check API balance and usage limits.",
        ServiceHTTPFailureKind.Service => "Service is temporarily unavailable. Retry shortly.",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
public sealed class ServiceHTTPFailure : Exception
{
    public int Status { get; }
    public ServiceHTTPFailureKind Kind { get; }
    public override string Message => Kind.Message() + (Status > 0 ? $" (HTTP {Status})" : "");
    public ServiceHTTPFailure(int status, byte[]? data = null)
    {
        Status = status;
        var codes = new HashSet<string>();
        if (data is not null)
        {
            try
            {
                using var doc = JsonDocument.Parse(data);
                var error = doc.RootElement;
                if (error.ValueKind == JsonValueKind.Object && error.TryGetProperty("error", out var nested) && nested.ValueKind == JsonValueKind.Object) error = nested;
                foreach (var key in new[] { "code", "type" })
                    if (error.ValueKind == JsonValueKind.Object && error.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String) codes.Add(value.GetString()!.ToLowerInvariant());
            }
            catch (JsonException) { }
        }
        string[] billing = ["insufficient_quota", "insufficient_balance", "credit_balance_exhausted",
                       "billing_hard_limit_reached", "billing_limit_reached", "usage_limit_reached",
                       "organization_usage_limit_exceeded", "spend_limit_reached", "arrearage", "isv.out_of_service"];
        string[] authentication = ["invalid_api_key", "invalidapikey", "expired_api_key", "api_key_expired",
                              "invalid_authentication", "authentication_error", "revoked_api_key"];
        if (status == 401 || codes.Overlaps(authentication)) Kind = ServiceHTTPFailureKind.Authentication;
        else if (status == 402 || codes.Overlaps(billing)) Kind = ServiceHTTPFailureKind.Billing;
        else if (codes.Overlaps(["rate_limit_exceeded", "rate_limit_error", "slow_down"])) Kind = ServiceHTTPFailureKind.RateLimit;
        else if (codes.Overlaps(["permission_denied", "access_denied", "insufficient_permissions"])) Kind = ServiceHTTPFailureKind.Permission;
        else if (codes.Overlaps(["model_not_found", "unknown_model", "model_not_exist", "model_not_available"])) Kind = ServiceHTTPFailureKind.Model;
        else Kind = status switch { 403 => ServiceHTTPFailureKind.Permission, 404 => ServiceHTTPFailureKind.Model, 429 => ServiceHTTPFailureKind.RateLimit, 400 or 422 => ServiceHTTPFailureKind.Parameters, _ => ServiceHTTPFailureKind.Service };
    }
    public static ServiceHTTPFailureKind? KindFromSafeMessage(string message)
    {
        var text = Regex.Replace(message, @" \(HTTP [0-9]{3}\)$", "");
        foreach (var kind in Enum.GetValues<ServiceHTTPFailureKind>()) if (kind.Message() == text) return kind;
        return null;
    }
}
