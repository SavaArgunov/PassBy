using Microsoft.AspNetCore.Authentication;
using PassByBack.Authorization;

// Namespace намеренно такой, чтобы в Program.cs не нужен был дополнительный using.
namespace Microsoft.Extensions.DependencyInjection;

public static class RoleAuthorizationExtensions
{
    /// <summary>
    /// Подключает рольовую авторизацию: подгрузку ролей из БД и политики.
    /// Вызывать после AddAuthentication / AddAuthorization.
    /// </summary>
    public static IServiceCollection AddRoleAuthorization(this IServiceCollection services)
    {
        services.AddScoped<IClaimsTransformation, RoleClaimsTransformation>();
        services.AddHostedService<RoleSeeder>();

        services.AddAuthorization(options =>
        {
            options.AddPolicy(AppPolicies.RequireSender, p => p.RequireRole(AppRoles.Sender));
            options.AddPolicy(AppPolicies.RequireDeliverer, p => p.RequireRole(AppRoles.Deliverer));
            options.AddPolicy(AppPolicies.RequireAdmin, p => p.RequireRole(AppRoles.Admin));
        });

        return services;
    }
}
