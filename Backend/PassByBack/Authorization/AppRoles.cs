namespace PassByBack.Authorization;

/// <summary>
/// Единое место для названий ролей и политик.
/// Используйте константы в [Authorize(Roles = AppRoles.Deliverer)] и т.п.
/// </summary>
public static class AppRoles
{
    public const string Sender = "Sender";
    public const string Deliverer = "Deliverer";
    public const string Admin = "Admin";

    /// <summary>Все роли системы. Заполняются в БД при старте (см. RoleSeeder).</summary>
    public static readonly IReadOnlyList<string> All = new[] { Sender, Deliverer, Admin };

    /// <summary>Роли, которые пользователь может получить сам.</summary>
    public static readonly IReadOnlySet<string> SelfAssignable =
        new HashSet<string>(new[] { Sender, Deliverer });

    /// <summary>Приводит строку к каноничному названию роли (без учёта регистра).</summary>
    public static bool TryNormalize(string? input, out string role)
    {
        role = All.FirstOrDefault(r =>
            string.Equals(r, input?.Trim(), StringComparison.OrdinalIgnoreCase)) ?? "";
        return role.Length > 0;
    }
}

public static class AppPolicies
{
    public const string RequireSender = "RequireSender";
    public const string RequireDeliverer = "RequireDeliverer";
    public const string RequireAdmin = "RequireAdmin";
}
