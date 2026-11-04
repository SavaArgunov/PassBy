using System.Globalization;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using PassByBack.Data;
using PassByBack.Models.DTOs.Auth;
using PassByBack.Models.Entities;

namespace PassByBack.Services;

public enum LoginStatus
{
    Success,
    InvalidCredentials,
    Blocked
}

public class AuthService
{
    // Контракт: ExpiresIn = 900 секунд
    private const int AccessTokenLifetimeSeconds = 900;

    private readonly AppDbContext _db;
    private readonly IPasswordHasher<UserAccount> _passwordHasher;
    private readonly IConfiguration _config;

    public AuthService(
        AppDbContext db,
        IPasswordHasher<UserAccount> passwordHasher,
        IConfiguration config)
    {
        _db = db;
        _passwordHasher = passwordHasher;
        _config = config;
    }

    public async Task<RegisterResponse?> RegisterAsync(
        RegisterRequest request,
        CancellationToken cancellationToken = default)
    {
        string email = request.EmailAddress.Trim().ToLowerInvariant();

        bool emailExists = await _db.UserAccounts
            .AnyAsync(x => x.EmailAddress == email, cancellationToken);

        if (emailExists)
            return null;

        var now = DateTime.UtcNow;

        var user = new UserAccount
        {
            EmailAddress = email,
            PhoneNumber = request.PhoneNumber.Trim(),
            RegisteredAtUtc = now,
            IsBlocked = false
        };

        // PasswordCredential зберігається першим, UserAccount посилається на нього через credentialId
        user.PasswordCredential = new PasswordCredential
        {
            PasswordHash = _passwordHasher.HashPassword(user, request.Password),
            CreatedAtUtc = now,
            ChangedAtUtc = now
        };

        _db.UserAccounts.Add(user);

        try
        {
            await _db.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateException ex)
            when (ex.InnerException is SqlException { Number: 2601 or 2627 })
        {
            // Паралельна реєстрація з тим самим email
            return null;
        }

        return new RegisterResponse
        {
            UserId = user.UserId,
            EmailAddress = user.EmailAddress,
            PhoneNumber = user.PhoneNumber,
            RegisteredAtUtc = user.RegisteredAtUtc
        };
    }

    public async Task<(LoginStatus Status, LoginResponse? Response)> LoginAsync(
        LoginRequest request,
        CancellationToken cancellationToken = default)
    {
        string email = request.EmailAddress.Trim().ToLowerInvariant();

        var user = await _db.UserAccounts
            .Include(x => x.PasswordCredential)
            .SingleOrDefaultAsync(x => x.EmailAddress == email, cancellationToken);

        if (user is null)
            return (LoginStatus.InvalidCredentials, null);

        var verification = _passwordHasher.VerifyHashedPassword(
            user,
            user.PasswordCredential.PasswordHash,
            request.Password);

        if (verification == PasswordVerificationResult.Failed)
            return (LoginStatus.InvalidCredentials, null);

        if (user.IsBlocked)
            return (LoginStatus.Blocked, null);

        return (LoginStatus.Success, new LoginResponse
        {
            AccessToken = CreateAccessToken(user),
            RefreshToken = string.Empty,
            ExpiresIn = AccessTokenLifetimeSeconds
        });
    }

    private string CreateAccessToken(UserAccount user)
    {
        var key = new SymmetricSecurityKey(
            Encoding.UTF8.GetBytes(_config["Jwt:Key"]!));

        var claims = new[]
        {
            // sub = числовий userId; саме його читає перевірка ролей
            new Claim(JwtRegisteredClaimNames.Sub,
                user.UserId.ToString(CultureInfo.InvariantCulture)),
            new Claim(JwtRegisteredClaimNames.Email, user.EmailAddress),
            new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())
        };

        var token = new JwtSecurityToken(
            issuer: _config["Jwt:Issuer"],
            audience: _config["Jwt:Audience"],
            claims: claims,
            expires: DateTime.UtcNow.AddSeconds(AccessTokenLifetimeSeconds),
            signingCredentials: new SigningCredentials(
                key,
                SecurityAlgorithms.HmacSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
