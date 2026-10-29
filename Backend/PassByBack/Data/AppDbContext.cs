using Microsoft.EntityFrameworkCore;
using PassByBack.Models;

namespace PassByBack.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options)
        : base(options)
    {
    }

    public DbSet<User> Users => Set<User>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<User>(entity =>
        {
            entity.ToTable("User");

            entity.HasKey(u => u.UserId);

            entity.Property(u => u.Email)
                .HasMaxLength(320)
                .IsRequired();

            entity.HasIndex(u => u.Email)
                .IsUnique();
        });
    }
}