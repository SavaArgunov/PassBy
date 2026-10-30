using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using PassByBack.Authorization;
using PassByBack.Contracts;
using PassByBack.Data;
using PassByBack.Models;

namespace PassByBack.Controllers;

[ApiController]
[Route("api/roles")]
[Authorize]
public class RolesController : ControllerBase
{
    private readonly AppDbContext _db;

    public RolesController(AppDbContext db)
    {
        _db = db;
    }

    //список всех ролей системы
    [HttpGet]
    public async Task<IActionResult> GetAll()
    {
        var roles = await _db.Roles
            .OrderBy(r => r.RoleId)
            .Select(r => new { r.RoleId, r.Name })
            .ToListAsync();

        return Ok(roles.Select(r => new
        {
            r.RoleId,
            r.Name,
            selfAssignable = AppRoles.SelfAssignable.Contains(r.Name)
        }));
    }

    //роли текущего пользователя
    [HttpGet("my")]
    public async Task<IActionResult> GetMine()
    {
        if (!TryGetUserId(out var userId))
        {
            return Unauthorized();
        }

        return Ok(new
        {
            userId,
            roles = await GetRoleNamesAsync(userId)
        });
    }

    //получение роли текущим пользователем
    [HttpPost("acquire")]
    public async Task<IActionResult> Acquire([FromBody] AcquireRoleRequest request)
    {
        if (!TryGetUserId(out var userId) ||
            !await _db.Users.AnyAsync(u => u.UserId == userId))
        {
            return Unauthorized();
        }

        if (!AppRoles.TryNormalize(request.Role, out var roleName))
        {
            return BadRequest(new
            {
                message = "Неизвестная роль",
                available = AppRoles.SelfAssignable
            });
        }

        if (!AppRoles.SelfAssignable.Contains(roleName))
        {
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                message = "Эту роль нельзя получить самостоятельно"
            });
        }

        var role = await _db.Roles.SingleOrDefaultAsync(r => r.Name == roleName);

        if (role == null)
        {
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                message = "Роль не найдена в базе данных"
            });
        }

        if (await _db.UserRoles.AnyAsync(ur => ur.UserId == userId && ur.RoleId == role.RoleId))
        {
            return Conflict(new { message = "Эта роль уже получена" });
        }

        _db.UserRoles.Add(new UserRole
        {
            UserId = userId,
            RoleId = role.RoleId
        });

        try
        {
            await _db.SaveChangesAsync();
        }
        catch (DbUpdateException)
        {
            //параллельный запрос уже добавил эту роль
            return Conflict(new { message = "Эта роль уже получена" });
        }

        return Ok(new
        {
            userId,
            roles = await GetRoleNamesAsync(userId)
        });
    }

    //эндпоинты для проверки рольовых прав, можно будет удалить

    [HttpGet("check/sender")]
    [Authorize(Policy = AppPolicies.RequireSender)]
    public IActionResult CheckSender() => Ok(new { message = "Доступ для Sender разрешён" });

    [HttpGet("check/deliverer")]
    [Authorize(Policy = AppPolicies.RequireDeliverer)]
    public IActionResult CheckDeliverer() => Ok(new { message = "Доступ для Deliverer разрешён" });

    [HttpGet("check/admin")]
    [Authorize(Policy = AppPolicies.RequireAdmin)]
    public IActionResult CheckAdmin() => Ok(new { message = "Доступ для Admin разрешён" });

    private bool TryGetUserId(out Guid userId)
    {
        var sub = User.FindFirst("sub")?.Value;
        return Guid.TryParse(sub, out userId);
    }

    private Task<List<string>> GetRoleNamesAsync(Guid userId) =>
        _db.UserRoles
            .Where(ur => ur.UserId == userId)
            .OrderBy(ur => ur.RoleId)
            .Select(ur => ur.Role.Name)
            .ToListAsync();
}
