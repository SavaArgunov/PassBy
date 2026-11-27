using System.ComponentModel.DataAnnotations;

namespace PassByBack.Models.DelivererOrders;

public class CreateDelivererOrderRequest : IValidatableObject
{
    [Required]
    [Range(-90, 90)]
    public double? StartLatitude { get; set; }

    [Required]
    [Range(-180, 180)]
    public double? StartLongitude { get; set; }

    [Required]
    [Range(-90, 90)]
    public double? EndLatitude { get; set; }

    [Required]
    [Range(-180, 180)]
    public double? EndLongitude { get; set; }

    [Required]
    public DateTimeOffset? DepartureTimeAtUtc { get; set; }

    public decimal? AvailableMaxWeight { get; set; }

    public decimal? AvailableMaxLength { get; set; }

    public decimal? AvailableMaxDepth { get; set; }

    public decimal? AvailableMaxHeight { get; set; }

    public decimal? MinRewardReceived { get; set; }

    public decimal? MaxRewardReceived { get; set; }

    public bool SaveAsDraft { get; set; }

    public IEnumerable<ValidationResult> Validate(
        ValidationContext validationContext)
    {
        var capacityFields = new[]
        {
            (nameof(AvailableMaxWeight), AvailableMaxWeight),
            (nameof(AvailableMaxLength), AvailableMaxLength),
            (nameof(AvailableMaxDepth), AvailableMaxDepth),
            (nameof(AvailableMaxHeight), AvailableMaxHeight)
        };

        foreach (var (name, value) in capacityFields)
        {
            if (value is decimal number &&
                (number <= 0 ||
                 number > 999999999.999m ||
                 decimal.Round(number, 3) != number))
            {
                yield return new ValidationResult(
                    $"{name} must be positive and fit decimal(12,3).",
                    new[] { name });
            }
        }

        var rewardFields = new[]
        {
            (nameof(MinRewardReceived), MinRewardReceived),
            (nameof(MaxRewardReceived), MaxRewardReceived)
        };

        foreach (var (name, value) in rewardFields)
        {
            if (value is decimal number &&
                (number < 0 ||
                 number > 9999999999999999.99m ||
                 decimal.Round(number, 2) != number))
            {
                yield return new ValidationResult(
                    $"{name} must be non-negative and fit decimal(18,2).",
                    new[] { name });
            }
        }

        if (MinRewardReceived.HasValue &&
            MaxRewardReceived.HasValue &&
            MinRewardReceived.Value > MaxRewardReceived.Value)
        {
            yield return new ValidationResult(
                "Minimum reward cannot exceed maximum reward.",
                new[]
                {
                    nameof(MinRewardReceived),
                    nameof(MaxRewardReceived)
                });
        }
    }
}