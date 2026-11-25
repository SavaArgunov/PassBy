namespace PassByBack.Models.DTOs.Users;

public class UserMeResponse
{
    public long UserId { get; set; }
    public string EmailAddress { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public bool IsBlocked { get; set; }
    public UserProfilesResponse Profiles { get; set; } = new();
}
