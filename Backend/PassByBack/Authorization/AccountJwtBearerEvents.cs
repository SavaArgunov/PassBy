using System.Globalization;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;

namespace PassByBack.Authorization;

public sealed class AccountJwtBearerEvents(IRoleStore roles) : JwtBearerEvents
{
    public override async Task TokenValidated(TokenValidatedContext context)
    {
        if (context.Principal?.Identity is not ClaimsIdentity identity ||
            !long.TryParse(identity.FindFirst(JwtRegisteredClaimNames.Sub)?.Value,
                NumberStyles.None, CultureInfo.InvariantCulture, out var userId) ||
            userId <= 0)
        {
            context.Fail("Invalid account identity.");
            return;
        }

        var account = await roles.GetAccountRolesAsync(userId, context.HttpContext.RequestAborted);
        if (account is not { IsBlocked: false })
        {
            context.Fail("Account is unavailable.");
            return;
        }

        foreach (var role in account.Roles.Where(role => !role.IsBlocked))
        {
            identity.AddClaim(new Claim(identity.RoleClaimType, role.Name));
        }
    }
}
