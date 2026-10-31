using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace PassByBack.Models.Entities;

[Table("Deliverer")]
public class Deliverer
{
    [Key]
    [ForeignKey(nameof(UserAccount))]
    [Column("userId")]
    public int UserId { get; set; }

    [Column("registeredAtUtc")]
    public DateTime RegisteredAtUtc { get; set; }

    [Column("isBlocked")]
    public bool IsBlocked { get; set; }

    public UserAccount UserAccount { get; set; } = null!;
}
