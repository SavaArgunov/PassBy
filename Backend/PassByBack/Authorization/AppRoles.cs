namespace PassByBack.Authorization;

/// <summary>
/// Єдине місце для назв ролей і політик.
/// Роль користувача = наявність запису в таблиці Deliverer або DeliveryRequester.
/// </summary>
public static class AppRoles
{
    public const string DeliveryRequester = "DeliveryRequester";
    public const string Deliverer = "Deliverer";

    public static readonly IReadOnlyList<string> All = new[] { DeliveryRequester, Deliverer };

    /// <summary>Приводить рядок до канонічної назви ролі (без урахування регістру).</summary>
    public static bool TryNormalize(string? input, out string role)
    {
        role = All.FirstOrDefault(r =>
            string.Equals(r, input?.Trim(), StringComparison.OrdinalIgnoreCase)) ?? "";
        return role.Length > 0;
    }
}

public static class AppPolicies
{
    public const string RequireDeliveryRequester = "RequireDeliveryRequester";
    public const string RequireDeliverer = "RequireDeliverer";
}
