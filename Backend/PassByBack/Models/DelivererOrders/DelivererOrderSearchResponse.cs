namespace PassByBack.Models.DelivererOrders;

public record DelivererOrderSearchResponse(
    long DelivererIntentId,

    double StartLatitude,
    double StartLongitude,

    double EndLatitude,
    double EndLongitude,

    DateTime DepartureTimeAtUtc,

    decimal? AvailableMaxWeight,
    decimal? AvailableMaxLength,
    decimal? AvailableMaxDepth,
    decimal? AvailableMaxHeight,

    decimal? MinRewardReceived,
    decimal? MaxRewardReceived
);