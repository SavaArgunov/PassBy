using NetTopologySuite.Geometries;

namespace PassByBack.Models.Entities;

public class DelivererIntent
{
    public long DelivererIntentId { get; set; }

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

    public long AuthorDelivererUserId { get; set; }

    // Navigation properties
    public Deliverer AuthorDeliverer { get; set; } = null!;
}