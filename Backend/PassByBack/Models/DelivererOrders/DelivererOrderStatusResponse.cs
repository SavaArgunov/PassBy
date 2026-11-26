namespace PassByBack.Models.DelivererOrders;

public record DelivererOrderStatusResponse(
    long DelivererIntentId,
    string PreviousOrderStatusCode,
    string OrderStatusCode,
    bool WasChanged
);