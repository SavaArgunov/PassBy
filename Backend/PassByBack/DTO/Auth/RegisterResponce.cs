namespace PassByBack.Models.DTOs.Auth;

public class RegisterResponse
{
    public int UserId { get; set; }
    public string EmailAddress { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public DateTime RegisteredAtUtc { get; set; }
}