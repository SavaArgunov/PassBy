using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using PassByBack.Data;
using PassByBack.Models.DTOs.Auth;
using PassByBack.Models.Entities;

namespace PassByBack.Services;

public class AuthService
{
    private readonly AppDbContext _db;
    private readonly IPasswordHasher<UserAccount> _passwordHasher;

    public AuthService(
        AppDbContext db,
        IPasswordHasher<UserAccount> passwordHasher)
    {
        _db = db;
        _passwordHasher = passwordHasher;
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

        var user = new UserAccount
        {
            EmailAddress = email,
            PhoneNumber = request.PhoneNumber,
            RegisteredAtUtc = DateTime.UtcNow,
            IsBlocked = false
        };

        var credential = new PasswordCredential
        {
            UserAccount = user,
            PasswordHash = _passwordHasher.HashPassword(
                user, request.Password),
            CreatedAtUtc = DateTime.UtcNow
        };

        _db.UserAccounts.Add(user);
        _db.PasswordCredentials.Add(credential);

        await _db.SaveChangesAsync(cancellationToken);

        return new RegisterResponse
        {
            UserId = user.UserId,
            EmailAddress = user.EmailAddress,
            PhoneNumber = user.PhoneNumber,
            RegisteredAtUtc = user.RegisteredAtUtc
        };
    }
}