using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;

namespace PassByBack.Authorization;

/// <summary>
/// Після перевірки JWT додає до користувача його ролі з БД як claims.
/// Роль надається, якщо є запис у Deliverer / DeliveryRequester і при цьому
/// не заблоковано ні акаунт, ні сам профіль. Нова роль діє одразу, без повторного входу.
/// </summary>
public class RoleClaimsTransformation : IClaimsTransformation
{
    private const string LoadedMarker = "passby:roles_loaded";

    private readonly IRoleStore _roles;

    public RoleClaimsTransformation(IRoleStore roles)
    {
        _roles = roles;
    }

    public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        if (principal.Identity is not ClaimsIdentity { IsAuthenticated: true })
        {
            return principal;
        }

        // Метод може викликатися кілька разів за запит, тому він ідемпотентний.
        if (principal.HasClaim(c => c.Type == LoadedMarker))
        {
            return principal;
        }

        var sub = (principal.FindFirst("sub") ?? principal.FindFirst(ClaimTypes.NameIdentifier))?.Value;

        if (!long.TryParse(sub, out var userId))
        {
            return principal;
        }

        var account = await _roles.GetAccountRolesAsync(userId);

        var clone = principal.Clone();
        var identity = (ClaimsIdentity)clone.Identity!;

        if (account is { IsBlocked: false })
        {
            foreach (var role in account.Roles.Where(r => !r.IsBlocked))
            {
                identity.AddClaim(new Claim(ClaimTypes.Role, role.Name));
            }
        }

        identity.AddClaim(new Claim(LoadedMarker, "1"));

        return clone;
    }
}
