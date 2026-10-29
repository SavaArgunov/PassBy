
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.IdentityModel.Tokens;
using PassByBack.Contracts;
using PassByBack.Data;
using PassByBack.Models;

namespace PassByBack.Controllers;

[ApiController]
[Route("api/auth")]
public class AuthController : ControllerBase
{
    private readonly AppDbContext _db;
    private readonly IPasswordHasher<User> _hasher;
    private readonly IConfiguration _config;

    public AuthController(
        AppDbContext db,
        IPasswordHasher<User> hasher,
        IConfiguration config)
    {
        _db = db;
        _hasher = hasher;
        _config = config;
    }

    // Регистрация нового пользователя
    [HttpPost("register")]
    public async Task<IActionResult> Register(
        [FromBody] RegisterRequest request)
    {
        var email = request.Email.Trim().ToLowerInvariant();

        // Проверяем, существует ли пользователь
        if (await _db.Users.AnyAsync(u => u.Email == email))
        {
            return Conflict(new
            {
                message = "Этот email уже зарегистрирован"
            });
        }

        // Создаём нового пользователя
        var user = new User
        {
            FirstName = request.FirstName.Trim(),
            SecondName = request.SecondName.Trim(),
            Email = email,
            DateOfBirth = request.DateOfBirth,
            PhoneNumber = request.PhoneNumber?.Trim()
        };

        // Хешируем пароль
        user.PasswordHash =
            _hasher.HashPassword(user, request.Password);

        // Добавляем пользователя в БД
        _db.Users.Add(user);

        try
        {
            await _db.SaveChangesAsync();
        }
        catch (DbUpdateException ex)
            when (ex.InnerException is SqlException sqlEx &&
                  (sqlEx.Number == 2601 || sqlEx.Number == 2627))
        {
            // Ошибка нарушения уникальности в SQL Server
            return Conflict(new
            {
                message = "Пользователь с такими данными уже существует"
            });
        }

        return StatusCode(201, new
        {
            userId = user.UserId,
            email = user.Email
        });
    }

    // Вход пользователя
    [HttpPost("login")]
    public async Task<IActionResult> Login(
        [FromBody] LoginRequest request)
    {
        var email = request.Email.Trim().ToLowerInvariant();

        // Ищем пользователя по email
        var user = await _db.Users
            .SingleOrDefaultAsync(u => u.Email == email);

        if (user == null)
        {
            return Unauthorized(new
            {
                message = "Неверный email или пароль"
            });
        }

        // Проверяем пароль
        var result = _hasher.VerifyHashedPassword(
            user,
            user.PasswordHash,
            request.Password
        );

        if (result == PasswordVerificationResult.Failed)
        {
            return Unauthorized(new
            {
                message = "Неверный email или пароль"
            });
        }

        // Генерируем JWT
        var (token, expiresAt) = CreateToken(user);

        return Ok(new
        {
            accessToken = token,
            tokenType = "Bearer",
            expiresAtUtc = expiresAt
        });
    }

    // Получение информации о текущем пользователе
    [Authorize]
    [HttpGet("me")]
    public IActionResult Me()
    {
        return Ok(new
        {
            userId = User.FindFirst("sub")?.Value
        });
    }

    // Генерация JWT-токена
    private (string Token, DateTime ExpiresAt) CreateToken(User user)
    {
        var key = new SymmetricSecurityKey(
            Encoding.UTF8.GetBytes(_config["Jwt:Key"]!)
        );

        var expiresAt = DateTime.UtcNow.AddHours(1);

        var claims = new[]
        {
            new Claim(
                JwtRegisteredClaimNames.Sub,
                user.UserId.ToString()
            ),
            new Claim(
                JwtRegisteredClaimNames.Email,
                user.Email
            ),
            new Claim(
                JwtRegisteredClaimNames.Jti,
                Guid.NewGuid().ToString()
            )
        };

        var jwt = new JwtSecurityToken(
            issuer: _config["Jwt:Issuer"],
            audience: _config["Jwt:Audience"],
            claims: claims,
            expires: expiresAt,
            signingCredentials: new SigningCredentials(
                key,
                SecurityAlgorithms.HmacSha256
            )
        );

        return (
            new JwtSecurityTokenHandler().WriteToken(jwt),
            expiresAt
        );
    }
}
