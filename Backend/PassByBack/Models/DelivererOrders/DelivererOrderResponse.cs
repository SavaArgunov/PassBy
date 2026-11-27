namespace PassByBack.Models.DelivererOrders;

public class DelivererOrderResponse
{
    public long DelivererIntentId { get; set; }

    public double StartLatitude { get; set; }

    public double StartLongitude { get; set; }

    public double EndLatitude { get; set; }

    public double EndLongitude { get; set; }

    public decimal? AvailableMaxWeight { get; set; }

    public decimal? AvailableMaxLength { get; set; }

    public decimal? AvailableMaxDepth { get; set; }

    public decimal? AvailableMaxHeight { get; set; }

    public decimal? MinRewardReceived { get; set; }

    public decimal? MaxRewardReceived { get; set; }

    public DateTime DepartureTimeAtUtc { get; set; }

    public DateTime CreatedAtUtc { get; set; }

    public string OrderStatusCode { get; set; } = null!;

    public long TotalInteractionCount { get; set; }

    public long ActiveDealCount { get; set; }

    public long FulfilledDealCount { get; set; }

    public long? ActiveDealId { get; set; }

    public string? ActiveDealExecutionStatusCode { get; set; }

    public bool IsAvailableAsTarget { get; set; }

    public bool IsAvailableAsInitiator { get; set; }
}