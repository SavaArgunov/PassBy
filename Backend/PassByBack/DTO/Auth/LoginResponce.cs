namespace PassByBack.Models.DTOs.Auth;

public class LoginResponse
{
    public string AccessToken { get; set; } = string.Empty;

    // Поки не реалізовано: для refresh-токенів у БД немає таблиці.
    public string RefreshToken { get; set; } = string.Empty;

    // Token lifetime, in seconds. Contract sample: 900.
    public int ExpiresIn { get; set; }
}
