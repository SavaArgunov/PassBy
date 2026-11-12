using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using PassByBack.Models.Entities;

namespace PassByBack.Data.Configurations;

internal static class VerificationConfiguration
{
    public static void ConfigureVerification(this ModelBuilder modelBuilder)
    {
        var utc = new ValueConverter<DateTime, DateTime>(
            value => value,
            value => DateTime.SpecifyKind(value, DateTimeKind.Utc));

        modelBuilder.Entity<VerificationProvider>(entity =>
        {
            entity.ToTable("VerificationProvider", "dbo");
            entity.HasKey(x => x.ProviderId);
            entity.Property(x => x.ProviderId).HasColumnName("providerId");
            entity.Property(x => x.ProviderCode).HasColumnName("providerCode").HasMaxLength(64).IsUnicode(false);
            entity.Property(x => x.IsEnabled).HasColumnName("isEnabled");
        });

        modelBuilder.Entity<VerificationOutcome>(entity =>
        {
            entity.ToTable("VerificationOutcome", "dbo");
            entity.HasKey(x => x.VerificationCode);
            entity.Property(x => x.VerificationCode).HasColumnName("verificationCode").HasMaxLength(64).IsUnicode(false);
        });

        modelBuilder.Entity<ValidatedDocument>(entity =>
        {
            entity.ToTable("ValidatedDocument", "dbo");
            entity.HasKey(x => x.DocumentId);
            entity.Property(x => x.DocumentId).HasColumnName("documentId");
            entity.Property(x => x.DocumentReference).HasColumnName("documentReference").HasMaxLength(512);
            entity.Property(x => x.ValidatedAtUtc).HasColumnName("validatedAtUtc").HasConversion(utc);
            entity.Property(x => x.VerificationProviderId).HasColumnName("verificationProviderId");
            entity.Property(x => x.UserId).HasColumnName("userId");

            entity.HasOne(x => x.Provider).WithMany().HasForeignKey(x => x.VerificationProviderId)
                .OnDelete(DeleteBehavior.NoAction);
            entity.HasOne<UserAccount>().WithMany().HasForeignKey(x => x.UserId)
                .OnDelete(DeleteBehavior.NoAction);
        });

        modelBuilder.Entity<IDCardData>(entity =>
        {
            entity.ToTable("IDCardData", "dbo");
            entity.HasKey(x => x.DocumentId);
            entity.Property(x => x.DocumentId).HasColumnName("documentId").ValueGeneratedNever();
            entity.Property(x => x.GivenName).HasColumnName("givenName").HasMaxLength(200);
            entity.Property(x => x.FamilyName).HasColumnName("familyName").HasMaxLength(200);
            entity.Property(x => x.BirthDate).HasColumnName("birthDate").HasColumnType("date");
            entity.Property(x => x.ExpiresAt).HasColumnName("expiresAt").HasColumnType("date");
            entity.Property(x => x.PhotoReference).HasColumnName("photoReference").HasMaxLength(2048);
            entity.HasOne<ValidatedDocument>().WithOne(x => x.IdCard).HasForeignKey<IDCardData>(x => x.DocumentId)
                .OnDelete(DeleteBehavior.NoAction);
        });

        modelBuilder.Entity<IdentityVerification>(entity =>
        {
            entity.ToTable("IdentityVerification", "dbo");
            entity.HasKey(x => x.VerificationId);
            entity.Property(x => x.VerificationId).HasColumnName("verificationId");
            entity.Property(x => x.DocumentId).HasColumnName("documentId");
            entity.Property(x => x.RequestId).HasColumnName("requestId");
            entity.Property(x => x.CheckedAtUtc).HasColumnName("checkedAtUtc").HasConversion(utc);
            entity.Property(x => x.ValidUntilUtc).HasColumnName("validUntilUtc").HasConversion(utc);
            entity.Property(x => x.VerificationCode).HasColumnName("verificationCode").HasMaxLength(64).IsUnicode(false);

            entity.HasOne(x => x.Document).WithMany().HasForeignKey(x => x.DocumentId)
                .OnDelete(DeleteBehavior.NoAction);
            entity.HasOne<VerificationOutcome>().WithMany().HasForeignKey(x => x.VerificationCode)
                .OnDelete(DeleteBehavior.NoAction);
        });
    }
}
