namespace PassByBack.Models.DTOs.Users;

public class UserProfilesResponse
{
    public ProfileRegistrationResponse DeliveryRequester { get; set; } = new();
    public ProfileRegistrationResponse Deliverer { get; set; } = new();
}
