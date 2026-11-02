using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using PassByBack.Authorization;

namespace PassByBack.Controllers;

[ApiController]
[Route("api/roles")]
[Authorize]
public class RolesController : ControllerBase
{
    private readonly IRoleStore _roles;

    public RolesController(IRoleStore roles)
    {
        _roles = roles;
    }

    // Перелік ролей системи
    [HttpGet]
    public IActionResult GetAll()
    {
        return Ok(AppRoles.All.Select(name => new { name }));
    }

    // Ролі поточного користувача
    [HttpGet("my")]
    public async Task<IActionResult> GetMine()
    {
        var account = await GetAccountAsync();

        if (account == null)
        {
            return Unauthorized();
        }

        if (account.IsBlocked)
        {
            return BlockedResponse();
        }

        return Ok(ToResponse(account));
    }

    // Отримання ролі поточним користувачем
    [HttpPost("acquire")]
    public async Task<IActionResult> Acquire([FromBody] AcquireRoleRequest request)
    {
        var account = await GetAccountAsync();

        if (account == null)
        {
            return Unauthorized();
        }

        if (account.IsBlocked)
        {
            return BlockedResponse();
        }

        if (!AppRoles.TryNormalize(request.Role, out var roleName))
        {
            return BadRequest(new
            {
                message = "Неизвестная роль",
                available = AppRoles.All
            });
        }

        if (account.Roles.Any(r => r.Name == roleName) ||
            !await _roles.AddRoleAsync(account.UserId, roleName))
        {
            return Conflict(new { message = "Эта роль уже получена" });
        }

        var updated = await _roles.GetAccountRolesAsync(account.UserId);

        return Ok(ToResponse(updated ?? account));
    }

    // --- Ендпоінти для перевірки рольових прав (можна видалити після тестів) ---

    [HttpGet("check/delivery-requester")]
    [Authorize(Policy = AppPolicies.RequireDeliveryRequester)]
    public IActionResult CheckDeliveryRequester() =>
        Ok(new { message = "Доступ для DeliveryRequester разрешён" });

    [HttpGet("check/deliverer")]
    [Authorize(Policy = AppPolicies.RequireDeliverer)]
    public IActionResult CheckDeliverer() =>
        Ok(new { message = "Доступ для Deliverer разрешён" });

    private async Task<AccountRoles?> GetAccountAsync()
    {
        if (!long.TryParse(User.FindFirst("sub")?.Value, out var userId))
        {
            return null;
        }

        return await _roles.GetAccountRolesAsync(userId);
    }

    private static object ToResponse(AccountRoles account) => new
    {
        userId = account.UserId,
        roles = account.Roles.Select(r => new
        {
            name = r.Name,
            registeredAtUtc = r.RegisteredAtUtc,
            isBlocked = r.IsBlocked
        })
    };

    private IActionResult BlockedResponse() =>
        StatusCode(StatusCodes.Status403Forbidden, new { message = "Аккаунт заблокирован" });
}
