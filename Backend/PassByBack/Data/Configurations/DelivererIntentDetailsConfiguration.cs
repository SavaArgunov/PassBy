using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using PassByBack.Models.Views;

namespace PassByBack.Data.Configurations;

public class DelivererIntentDetailsConfiguration
    : IEntityTypeConfiguration<DelivererIntentDetails>
{
    public void Configure(
        EntityTypeBuilder<DelivererIntentDetails> entity)
    {
        entity.HasNoKey();

        entity.ToView("vDelivererIntentDetails", "dbo");

        entity.Property(x => x.StartingCoordinates)
            .HasColumnType("geography");

        entity.Property(x => x.EndCoordinates)
            .HasColumnType("geography");

        entity.Property(x => x.AvailableMaxWeight)
            .HasPrecision(12, 3);

        entity.Property(x => x.AvailableMaxLength)
            .HasPrecision(12, 3);

        entity.Property(x => x.AvailableMaxDepth)
            .HasPrecision(12, 3);

        entity.Property(x => x.AvailableMaxHeight)
            .HasPrecision(12, 3);

        entity.Property(x => x.MinRewardReceived)
            .HasPrecision(18, 2);

        entity.Property(x => x.MaxRewardReceived)
            .HasPrecision(18, 2);

        entity.Property(x => x.OrderStatusCode)
            .HasColumnType("varchar(64)");

        entity.Property(x => x.ActiveDealExecutionStatusCode)
            .HasColumnType("varchar(64)");

        foreach (var property in entity.Metadata.GetProperties())
        {
            var name = property.Name;

            property.SetColumnName(
                char.ToLowerInvariant(name[0]) + name.Substring(1));
        }
    }
}