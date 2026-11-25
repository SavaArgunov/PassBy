namespace PassByBack.Models.DelivererOrders;

public sealed record CreateDelivererOrderResponse(
    long DelivererIntentId,
    string OrderStatusCode
);