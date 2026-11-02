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
}