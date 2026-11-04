using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace PassByBack.Models.Entities;

[Table("UserAccount")]
public class UserAccount
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    [Column("userId")]
    public long UserId { get; set; }

    // У БД UserAccount посилається на PasswordCredential (credentialId NOT NULL)
    [Column("credentialId")]
    public long CredentialId { get; set; }

    [Required]
    [MaxLength(320)]
    [Column("emailAddress")]
    public string EmailAddress { get; set; } = string.Empty;

    [Required]
    [MaxLength(32)]
    [Column("phoneNumber")]
    public string PhoneNumber { get; set; } = string.Empty;

    [Column("registeredAtUtc")]
    public DateTime RegisteredAtUtc { get; set; }

    [Column("isBlocked")]
    public bool IsBlocked { get; set; }

    public PasswordCredential PasswordCredential { get; set; } = null!;
    public DeliveryRequester? DeliveryRequester { get; set; }
    public Deliverer? Deliverer { get; set; }
}
