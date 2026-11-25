using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace PassByBack.Models.Entities;

[Table("PasswordCredential")]
public class PasswordCredential
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    [Column("credentialId")]
    public long CredentialId { get; set; }

    [Required]
    [MaxLength(1024)]
    [Column("passwordHash")]
    public string PasswordHash { get; set; } = string.Empty;

    [Column("createdAtUtc")]
    public DateTime CreatedAtUtc { get; set; }

    // У БД стовпець NOT NULL (за замовчуванням SYSUTCDATETIME())
    [Column("changedAtUtc")]
    public DateTime ChangedAtUtc { get; set; }
}
