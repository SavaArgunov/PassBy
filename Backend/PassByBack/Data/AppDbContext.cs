
using Microsoft.EntityFrameworkCore;
using PassByBack.Models.Entities;

namespace PassByBack.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options)
        : base(options)
    {
    }

    public DbSet<UserAccount> UserAccounts => Set<UserAccount>();
    public DbSet<PasswordCredential> PasswordCredentials => Set<PasswordCredential>();
    public DbSet<DeliveryRequester> DeliveryRequesters => Set<DeliveryRequester>();
    public DbSet<Deliverer> Deliverers => Set<Deliverer>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        modelBuilder.Entity<UserAccount>(entity =>
        {
            entity.HasKey(x => x.UserId);

            entity.HasIndex(x => x.EmailAddress)
                .IsUnique();

            // entity.Property(x => x.RegisteredAtUtc)
            //     .HasDefaultValueSql("SYSUTCDATETIME()");

            entity.Property(x => x.IsBlocked)
                .HasDefaultValue(false);
        });

        modelBuilder.Entity<PasswordCredential>(entity =>
        {
            entity.HasKey(x => x.UserId);

            entity.HasOne(x => x.UserAccount)
                .WithOne(x => x.PasswordCredential)
                .HasForeignKey<PasswordCredential>(x => x.UserId)
                .OnDelete(DeleteBehavior.NoAction);
        });

        modelBuilder.Entity<DeliveryRequester>(entity =>
        {
            entity.HasKey(x => x.UserId);

            entity.HasOne(x => x.UserAccount)
                .WithOne(x => x.DeliveryRequester)
                .HasForeignKey<DeliveryRequester>(x => x.UserId)
                .OnDelete(DeleteBehavior.NoAction);
        });

        modelBuilder.Entity<Deliverer>(entity =>
        {
            entity.HasKey(x => x.UserId);

            entity.HasOne(x => x.UserAccount)
                .WithOne(x => x.Deliverer)
                .HasForeignKey<Deliverer>(x => x.UserId)
                .OnDelete(DeleteBehavior.NoAction);
        });
    }
}
