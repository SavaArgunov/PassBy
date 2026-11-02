using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace PassByBack.Models.Entities;

[Table("UserAccount")]
public class UserAccount
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    [Column("userId")]
    public int UserId { get; set; }

    [Required]
    [Column("emailAddress")]
    public string EmailAddress { get; set; } = string.Empty;

    [Required]
    [Column("phoneNumber")]
    public string PhoneNumber { get; set; } = string.Empty;

    [Column("registeredAtUtc")]
    public DateTime RegisteredAtUtc { get; set; }

    [Column("isBlocked")]
    public bool IsBlocked { get; set; }

    public PasswordCredential? PasswordCredential { get; set; }
    public DeliveryRequester? DeliveryRequester { get; set; }
    public Deliverer? Deliverer { get; set; }
}