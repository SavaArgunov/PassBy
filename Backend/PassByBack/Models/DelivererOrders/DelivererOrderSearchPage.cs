namespace PassByBack.Models.DelivererOrders;

public record DelivererOrderSearchPage(
    IReadOnlyList<DelivererOrderSearchResponse> Items,
    int Page,
    int PageSize,
    bool HasMore
);