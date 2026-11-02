namespace PassByBack.Authorization;

public sealed record RoleRecord(string Name, DateTime RegisteredAtUtc, bool IsBlocked);

public sealed record AccountRoles(long UserId, bool IsBlocked, IReadOnlyList<RoleRecord> Roles);

/// <summary>
/// Доступ до ролей користувача. Самодостатній шар: працює напряму з таблицями
/// UserAccount, Deliverer, DeliveryRequester і не залежить від сутностей та DbContext.
/// </summary>
public interface IRoleStore
{
    /// <summary>Повертає акаунт з ролями або null, якщо такого користувача немає.</summary>
    Task<AccountRoles?> GetAccountRolesAsync(long userId, CancellationToken cancellationToken = default);

    /// <summary>true — роль додано, false — користувач її вже мав.</summary>
    Task<bool> AddRoleAsync(long userId, string roleName, CancellationToken cancellationToken = default);
}
