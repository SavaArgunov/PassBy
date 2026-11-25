using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using PassByBack.Models.Entities;

namespace PassByBack.Data.Configurations;

public class DelivererIntentConfiguration
    : IEntityTypeConfiguration<DelivererIntent>
{
    public void Configure(
        EntityTypeBuilder<DelivererIntent> entity)
    {
        // Table configuration
        entity.ToTable("DelivererIntent", "dbo", table =>
        {
            table.IsTemporal(temporal =>
            {
                temporal.HasPeriodStart("validFrom");
                temporal.HasPeriodEnd("validTo");

                temporal.UseHistoryTable(
                    "DelivererIntentHistory",
                    "dbo");
            });

            table.HasTrigger(
                "TR_DelivererIntent_ImmutableFinalStates");
        });

        // Primary key
        entity.HasKey(x => x.DelivererIntentId);

        entity.Property(x => x.DelivererIntentId)
            .HasColumnName("delivererIntentId")
            .ValueGeneratedOnAdd();

        // Coordinates
        entity.Property(x => x.StartingCoordinates)
            .HasColumnName("startingCoordinates")
            .HasColumnType("geography")
            .IsRequired();

        entity.Property(x => x.EndCoordinates)
            .HasColumnName("endCoordinates")
            .HasColumnType("geography")
            .IsRequired();

        // Capacity
        entity.Property(x => x.AvailableMaxWeight)
            .HasColumnName("availableMaxWeight")
            .HasPrecision(12, 3);

        entity.Property(x => x.AvailableMaxLength)
            .HasColumnName("availableMaxLength")
            .HasPrecision(12, 3);

        entity.Property(x => x.AvailableMaxDepth)
            .HasColumnName("availableMaxDepth")
            .HasPrecision(12, 3);

        entity.Property(x => x.AvailableMaxHeight)
            .HasColumnName("availableMaxHeight")
            .HasPrecision(12, 3);

        // Reward
        entity.Property(x => x.MinRewardReceived)
            .HasColumnName("minRewardReceived")
            .HasPrecision(18, 2);

        entity.Property(x => x.MaxRewardReceived)
            .HasColumnName("maxRewardReceived")
            .HasPrecision(18, 2);

        // Dates
        entity.Property(x => x.DepartureTimeAtUtc)
            .HasColumnName("departureTimeAtUtc")
            .HasColumnType("datetime2(7)");

        entity.Property(x => x.CreatedAtUtc)
            .HasColumnName("createdAtUtc")
            .HasColumnType("datetime2(7)")
            .HasDefaultValueSql("SYSUTCDATETIME()");

        // Status
        entity.Property(x => x.OrderStatusCode)
            .HasColumnName("orderStatusCode")
            .HasColumnType("varchar(64)")
            .IsRequired();

        // Foreign key
        entity.Property(x => x.AuthorDelivererUserId)
            .HasColumnName("authorDelivererUserId");

        entity.HasOne(x => x.AuthorDeliverer)
            .WithMany()
            .HasForeignKey(x => x.AuthorDelivererUserId)
            .OnDelete(DeleteBehavior.NoAction);
    }
}