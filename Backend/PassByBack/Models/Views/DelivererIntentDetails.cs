using NetTopologySuite.Geometries;

namespace PassByBack.Models.Views;

public class DelivererIntentDetails
{
    public long DelivererIntentId { get; set; }

    public long AuthorDelivererUserId { get; set; }

    public Point StartingCoordinates { get; set; } = null!;

    public Point EndCoordinates { get; set; } = null!;

    public decimal? AvailableMaxWeight { get; set; }

    public decimal? AvailableMaxLength { get; set; }

    public decimal? AvailableMaxDepth { get; set; }

    public decimal? AvailableMaxHeight { get; set; }

    public decimal? MinRewardReceived { get; set; }

    public decimal? MaxRewardReceived { get; set; }

    public DateTime DepartureTimeAtUtc { get; set; }

    public DateTime CreatedAtUtc { get; set; }

    public string OrderStatusCode { get; set; } = null!;

    public long? TotalInteractionCount { get; set; }

    public long? ActiveDealCount { get; set; }

    public long? FulfilledDealCount { get; set; }

    public long? ActiveDealId { get; set; }

    public string? ActiveDealExecutionStatusCode { get; set; }

    public bool? IsAvailableAsTarget { get; set; }

    public bool? IsAvailableAsInitiator { get; set; }
}