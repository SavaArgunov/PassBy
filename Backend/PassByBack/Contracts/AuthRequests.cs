using System.ComponentModel.DataAnnotations;

namespace PassByBack.Contracts;

public class RegisterRequest
{
    [Required, MaxLength(100)]
    public string FirstName { get; set; } = "";

    [Required, MaxLength(100)]
    public string SecondName { get; set; } = "";

    [Required, EmailAddress, MaxLength(320)]
    public string Email { get; set; } = "";

    [Required, MinLength(12), MaxLength(128)]
    public string Password { get; set; } = "";

    public DateOnly? DateOfBirth { get; set; }

    [MaxLength(30)]
    public string? PhoneNumber { get; set; }
}

public class LoginRequest
{
    [Required]
    public string Email { get; set; } = "";

    [Required]
    public string Password { get; set; } = "";
}