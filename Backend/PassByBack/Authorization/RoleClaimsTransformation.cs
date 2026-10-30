using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using PassByBack.Data;

namespace PassByBack.Authorization;

/// <summary>
/// После проверки JWT добавляет к пользователю его роли из БД как claims.
/// Благодаря этому [Authorize(Roles = "...")] и политики работают без изменения
/// выдачи токена, а новая роль действует сразу, без повторного входа.
/// </summary>
public class RoleClaimsTransformation : IClaimsTransformation
{
    private const string LoadedMarker = "passby:roles_loaded";

    private readonly AppDbContext _db;

    public RoleClaimsTransformation(AppDbContext db)
    {
        _db = db;
    }

    public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        if (principal.Identity is not ClaimsIdentity { IsAuthenticated: true })
        {
            return principal;
        }

        // Метод может вызываться несколько раз за запрос, поэтому он идемпотентный.
        if (principal.HasClaim(c => c.Type == LoadedMarker))
        {
            return principal;
        }

        var sub = (principal.FindFirst("sub") ?? principal.FindFirst(ClaimTypes.NameIdentifier))?.Value;

        if (!Guid.TryParse(sub, out var userId))
        {
            return principal;
        }

        var roles = await _db.UserRoles
            .Where(ur => ur.UserId == userId)
            .Select(ur => ur.Role.Name)
            .ToListAsync();

        var clone = principal.Clone();
        var identity = (ClaimsIdentity)clone.Identity!;

        foreach (var role in roles)
        {
            identity.AddClaim(new Claim(ClaimTypes.Role, role));
        }

        identity.AddClaim(new Claim(LoadedMarker, "1"));

        return clone;
    }
}
