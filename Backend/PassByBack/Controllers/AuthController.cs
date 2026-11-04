using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using PassByBack.Models.DTOs.Auth;
using PassByBack.Services;

namespace PassByBack.Controllers;

[ApiController]
[Route("api/auth")]
public class AuthController : ControllerBase
{
    private readonly AuthService _authService;

    public AuthController(AuthService authService)
    {
        _authService = authService;
    }

    [HttpPost("register")]
    public async Task<ActionResult<RegisterResponse>> Register(
        [FromBody] RegisterRequest request,
        CancellationToken cancellationToken)
    {
        var result = await _authService.RegisterAsync(
            request, cancellationToken);

        if (result is null)
        {
            return Conflict(new
            {
                message = "User with this email already exists"
            });
        }

        return StatusCode(StatusCodes.Status201Created, result);
    }

    [HttpPost("login")]
    public async Task<IActionResult> Login(
        [FromBody] LoginRequest request,
        CancellationToken cancellationToken)
    {
        var (status, response) = await _authService.LoginAsync(
            request, cancellationToken);

        if (status == LoginStatus.Blocked)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                message = "Account is blocked"
            });
        }

        if (status != LoginStatus.Success)
        {
            return Unauthorized(new
            {
                message = "Invalid email or password"
            });
        }

        return Ok(response);
    }
}
