using System.ComponentModel.DataAnnotations;

namespace PassByBack.Contracts;

public class AcquireRoleRequest
{
    [Required, MaxLength(50)]
    public string Role { get; set; } = "";
}
