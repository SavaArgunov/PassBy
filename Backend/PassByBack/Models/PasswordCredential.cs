using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace PassByBack.Models.Entities;

[Table("PasswordCredential")]
public class PasswordCredential
{
    [Key]
    [ForeignKey(nameof(UserAccount))]
    [Column("userId")]
    public int UserId { get; set; }

    [Required]
    [Column("passwordHash")]
    public string PasswordHash { get; set; } = string.Empty;

    [Column("createdAtUtc")]
    public DateTime CreatedAtUtc { get; set; }

    [Column("changedAtUtc")]
    public DateTime? ChangedAtUtc { get; set; }

    public UserAccount UserAccount { get; set; } = null!;
}