using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using PassByBack.Data;
using PassByBack.Models;

namespace PassByBack.Authorization;

/// <summary>
/// При старте приложения гарантирует, что все роли из AppRoles есть в таблице Role.
/// Безопасно запускать повторно: уже существующие роли не дублируются.
/// </summary>
public class RoleSeeder : IHostedService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<RoleSeeder> _logger;

    public RoleSeeder(IServiceScopeFactory scopeFactory, ILogger<RoleSeeder> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

            var existing = await db.Roles
                .Select(r => r.Name)
                .ToListAsync(cancellationToken);

            foreach (var name in AppRoles.All.Except(existing))
            {
                db.Roles.Add(new Role { Name = name });
            }

            await db.SaveChangesAsync(cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Не удалось заполнить таблицу Role");
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
