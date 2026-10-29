namespace PassByBack.Models;

public class User
{
    public Guid UserId { get; set; } = Guid.NewGuid();

    public string FirstName { get; set; } = "";
    public string SecondName { get; set; } = "";

    public string PasswordHash { get; set; } = "";

    public DateOnly? DateOfBirth { get; set; }
    public string? PhoneNumber { get; set; }
    public string? AvatarUrl { get; set; }

    public string Email { get; set; } = "";

    public DateTime CreatedAtUtc { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAtUtc { get; set; } = DateTime.UtcNow;
}