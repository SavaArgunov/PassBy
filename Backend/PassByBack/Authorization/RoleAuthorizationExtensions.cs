using PassByBack.Authorization;

// Namespace навмисно такий, щоб у Program.cs не потрібен був додатковий using.
namespace Microsoft.Extensions.DependencyInjection;

public static class RoleAuthorizationExtensions
{
    /// <summary>
    /// Підключає рольову авторизацію: сховище ролей, підвантаження ролей у claims і політики.
    /// Потребує рядка підключення ConnectionStrings:DefaultConnection.
    /// Викликати після AddAuthentication / AddAuthorization.
    /// </summary>
    public static IServiceCollection AddRoleAuthorization(this IServiceCollection services)
    {
        services.AddScoped<IRoleStore, SqlRoleStore>();
        services.AddScoped<AccountJwtBearerEvents>();

        services.AddAuthorization(options =>
        {
            options.AddPolicy(AppPolicies.RequireDeliveryRequester,
                p => p.RequireRole(AppRoles.DeliveryRequester));
            options.AddPolicy(AppPolicies.RequireDeliverer,
                p => p.RequireRole(AppRoles.Deliverer));
        });

        return services;
    }
}
