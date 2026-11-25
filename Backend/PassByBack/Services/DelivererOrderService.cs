using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using PassByBack.Data;
using PassByBack.Models.DelivererOrders;
using PassByBack.Models.Views;

namespace PassByBack.Services;

public class DelivererOrderService
{
    private readonly AppDbContext _db;

    public DelivererOrderService(AppDbContext db)
    {
        _db = db;
    }

    public async Task<CreateDelivererOrderResponse> CreateAsync(
        long userId,
        CreateDelivererOrderRequest request,
        CancellationToken cancellationToken = default)
    {
        var connection = _db.Database.GetDbConnection();

        await _db.Database.OpenConnectionAsync(cancellationToken);

        try
        {
            using var command = connection.CreateCommand();

            command.CommandText = "dbo.CreateDelivererOrder";
            command.CommandType = CommandType.StoredProcedure;

            command.Parameters.Add(new SqlParameter(
                "@AuthorDelivererUserId", SqlDbType.BigInt)
            {
                Value = userId
            });

            command.Parameters.Add(new SqlParameter(
                "@StartLatitude", SqlDbType.Float)
            {
                Value = request.StartLatitude!.Value
            });

            command.Parameters.Add(new SqlParameter(
                "@StartLongitude", SqlDbType.Float)
            {
                Value = request.StartLongitude!.Value
            });

            command.Parameters.Add(new SqlParameter(
                "@EndLatitude", SqlDbType.Float)
            {
                Value = request.EndLatitude!.Value
            });

            command.Parameters.Add(new SqlParameter(
                "@EndLongitude", SqlDbType.Float)
            {
                Value = request.EndLongitude!.Value
            });

            command.Parameters.Add(new SqlParameter(
                "@DepartureTimeAtUtc", SqlDbType.DateTime2)
            {
                Value = request.DepartureTimeAtUtc!.Value.UtcDateTime
            });

            command.Parameters.Add(DecimalParameter(
                "@AvailableMaxWeight",
                request.AvailableMaxWeight, 12, 3));

            command.Parameters.Add(DecimalParameter(
                "@AvailableMaxLength",
                request.AvailableMaxLength, 12, 3));

            command.Parameters.Add(DecimalParameter(
                "@AvailableMaxDepth",
                request.AvailableMaxDepth, 12, 3));

            command.Parameters.Add(DecimalParameter(
                "@AvailableMaxHeight",
                request.AvailableMaxHeight, 12, 3));

            command.Parameters.Add(DecimalParameter(
                "@MinRewardReceived",
                request.MinRewardReceived, 18, 2));

            command.Parameters.Add(DecimalParameter(
                "@MaxRewardReceived",
                request.MaxRewardReceived, 18, 2));

            command.Parameters.Add(new SqlParameter(
                "@SaveAsDraft", SqlDbType.Bit)
            {
                Value = request.SaveAsDraft
            });

            using var reader = await command.ExecuteReaderAsync(
                cancellationToken);

            if (!await reader.ReadAsync(cancellationToken))
            {
                throw new InvalidOperationException(
                    "CreateDelivererOrder returned no result.");
            }

            return new CreateDelivererOrderResponse(
                reader.GetInt64(
                    reader.GetOrdinal("delivererIntentId")),
                reader.GetString(
                    reader.GetOrdinal("orderStatusCode"))
            );
        }
        finally
        {
            await _db.Database.CloseConnectionAsync();
        }
    }

    private static SqlParameter DecimalParameter(
        string name,
        decimal? value,
        byte precision,
        byte scale)
    {
        return new SqlParameter(name, SqlDbType.Decimal)
        {
            Precision = precision,
            Scale = scale,
            Value = (object?)value ?? DBNull.Value
        };
    }
    public async Task<List<DelivererOrderResponse>> GetAllAsync(
        long userId,
        CancellationToken cancellationToken = default)
    {
        var orders = await _db.DelivererIntentDetails
            .Where(x => x.AuthorDelivererUserId == userId)
            .OrderByDescending(x => x.CreatedAtUtc)
            .ThenByDescending(x => x.DelivererIntentId)
            .ToListAsync(cancellationToken);

        return orders.Select(ToResponse).ToList();
    }
    
    public async Task<DelivererOrderResponse?> GetByIdAsync(
        long userId,
        long orderId,
        CancellationToken cancellationToken = default)
    {
        var order = await _db.DelivererIntentDetails
            .FirstOrDefaultAsync(
                x => x.DelivererIntentId == orderId &&
                     x.AuthorDelivererUserId == userId,
                cancellationToken);

        return order is null ? null : ToResponse(order);
    }
    
    private static DelivererOrderResponse ToResponse(
        DelivererIntentDetails order)
    {
        return new DelivererOrderResponse
        {
            DelivererIntentId = order.DelivererIntentId,

            StartLatitude = order.StartingCoordinates.Y,
            StartLongitude = order.StartingCoordinates.X,

            EndLatitude = order.EndCoordinates.Y,
            EndLongitude = order.EndCoordinates.X,

            AvailableMaxWeight = order.AvailableMaxWeight,
            AvailableMaxLength = order.AvailableMaxLength,
            AvailableMaxDepth = order.AvailableMaxDepth,
            AvailableMaxHeight = order.AvailableMaxHeight,

            MinRewardReceived = order.MinRewardReceived,
            MaxRewardReceived = order.MaxRewardReceived,

            DepartureTimeAtUtc = DateTime.SpecifyKind(
                order.DepartureTimeAtUtc,
                DateTimeKind.Utc),

            CreatedAtUtc = DateTime.SpecifyKind(
                order.CreatedAtUtc,
                DateTimeKind.Utc),

            OrderStatusCode = order.OrderStatusCode,

            TotalInteractionCount =
                order.TotalInteractionCount ?? 0,

            ActiveDealCount = order.ActiveDealCount ?? 0,

            FulfilledDealCount = order.FulfilledDealCount ?? 0,

            ActiveDealId = order.ActiveDealId,

            ActiveDealExecutionStatusCode =
                order.ActiveDealExecutionStatusCode,

            IsAvailableAsTarget =
                order.IsAvailableAsTarget ?? false,

            IsAvailableAsInitiator =
                order.IsAvailableAsInitiator ?? false
        };
    }
}