
using Microsoft.EntityFrameworkCore;
using PassByBack.Data.Configurations;
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

    public DbSet<VerificationProvider> VerificationProviders => Set<VerificationProvider>();
    public DbSet<VerificationOutcome> VerificationOutcomes => Set<VerificationOutcome>();
    public DbSet<ValidatedDocument> ValidatedDocuments => Set<ValidatedDocument>();
    public DbSet<IdentityVerification> IdentityVerifications => Set<IdentityVerification>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // Схему БД створюють SQL-скрипти з папки Database/ (без EF-міграцій).

        modelBuilder.Entity<UserAccount>(entity =>
        {
            entity.HasKey(x => x.UserId);

            entity.HasIndex(x => x.EmailAddress)
                .IsUnique();

            entity.HasIndex(x => x.CredentialId)
                .IsUnique();

            entity.Property(x => x.IsBlocked)
                .HasDefaultValue(false);

            // UserAccount.credentialId -> PasswordCredential.credentialId
            entity.HasOne(x => x.PasswordCredential)
                .WithOne()
                .HasForeignKey<UserAccount>(x => x.CredentialId)
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

        modelBuilder.ConfigureVerification();
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(AppDbContext).Assembly);
    }
}
