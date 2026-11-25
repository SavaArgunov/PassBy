using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using PassByBack.Models.Entities;

namespace PassByBack.Models.DelivererOrders;

public static class DelivererOrderPatch
{
    public static CreateDelivererOrderRequest Apply(
        DelivererIntent order,
        JsonElement patch)
    {
        if (patch.ValueKind != JsonValueKind.Object)
        {
            throw new ValidationException(
                "PATCH body must be a JSON object.");
        }

        // Заполняем DTO текущими значениями заказа.
        var request = new CreateDelivererOrderRequest
        {
            StartLatitude = order.StartingCoordinates.Y,
            StartLongitude = order.StartingCoordinates.X,

            EndLatitude = order.EndCoordinates.Y,
            EndLongitude = order.EndCoordinates.X,

            DepartureTimeAtUtc = new DateTimeOffset(
                DateTime.SpecifyKind(
                    order.DepartureTimeAtUtc,
                    DateTimeKind.Utc)),

            AvailableMaxWeight = order.AvailableMaxWeight,
            AvailableMaxLength = order.AvailableMaxLength,
            AvailableMaxDepth = order.AvailableMaxDepth,
            AvailableMaxHeight = order.AvailableMaxHeight,

            MinRewardReceived = order.MinRewardReceived,
            MaxRewardReceived = order.MaxRewardReceived
        };

        var processedFields = new HashSet<string>();

        foreach (var property in patch.EnumerateObject())
        {
            if (!processedFields.Add(property.Name))
            {
                throw new ValidationException(
                    $"Duplicate field: {property.Name}");
            }

            switch (property.Name)
            {
                case "startLatitude":
                    request.StartLatitude =
                        property.Value.Deserialize<double?>();
                    break;

                case "startLongitude":
                    request.StartLongitude =
                        property.Value.Deserialize<double?>();
                    break;

                case "endLatitude":
                    request.EndLatitude =
                        property.Value.Deserialize<double?>();
                    break;

                case "endLongitude":
                    request.EndLongitude =
                        property.Value.Deserialize<double?>();
                    break;

                case "departureTimeAtUtc":
                    request.DepartureTimeAtUtc =
                        property.Value.Deserialize<DateTimeOffset?>();
                    break;

                case "availableMaxWeight":
                    request.AvailableMaxWeight =
                        property.Value.Deserialize<decimal?>();
                    break;

                case "availableMaxLength":
                    request.AvailableMaxLength =
                        property.Value.Deserialize<decimal?>();
                    break;

                case "availableMaxDepth":
                    request.AvailableMaxDepth =
                        property.Value.Deserialize<decimal?>();
                    break;

                case "availableMaxHeight":
                    request.AvailableMaxHeight =
                        property.Value.Deserialize<decimal?>();
                    break;

                case "minRewardReceived":
                    request.MinRewardReceived =
                        property.Value.Deserialize<decimal?>();
                    break;

                case "maxRewardReceived":
                    request.MaxRewardReceived =
                        property.Value.Deserialize<decimal?>();
                    break;

                default:
                    throw new ValidationException(
                        $"Field '{property.Name}' cannot be updated.");
            }
        }

        if (processedFields.Count == 0)
        {
            throw new ValidationException(
                "PATCH must contain at least one field.");
        }

        var results = new List<ValidationResult>();

        if (!Validator.TryValidateObject(
                request,
                new ValidationContext(request),
                results,
                validateAllProperties: true))
        {
            throw new ValidationException(
                string.Join("; ",
                    results.Select(r => r.ErrorMessage)));
        }

        return request;
    }
}