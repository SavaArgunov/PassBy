using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using PassByBack.Data;
using PassByBack.Models.DelivererOrders;
using PassByBack.Models.Views;
using System.Text.Json;
using NetTopologySuite.Geometries;

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
    
    public async Task<DelivererOrderResponse?> UpdateAsync(
    long userId,
    long orderId,
    JsonElement patch,
    CancellationToken cancellationToken = default)
{
    await using var transaction =
        await _db.Database.BeginTransactionAsync(cancellationToken);

    await AcquireOrderLockAsync(orderId, cancellationToken);

    // Шукаємо замовлення поточного користувача.
    var order = await _db.DelivererIntents
        .FirstOrDefaultAsync(
            x => x.DelivererIntentId == orderId &&
                 x.AuthorDelivererUserId == userId,
            cancellationToken);

    if (order is null)
    {
        return null;
    }

    // Перевіряємо пов'язані угоди.
    var details = await _db.DelivererIntentDetails
        .FirstAsync(
            x => x.DelivererIntentId == orderId,
            cancellationToken);

    if (details.ActiveDealCount > 0 ||
        details.FulfilledDealCount > 0)
    {
        throw new OrderUpdateConflictException(
            "Order has an active or fulfilled deal.");
    }

    // Застосовуємо PATCH та перевіряємо результат.
    var request = DelivererOrderPatch.Apply(order, patch);

    // Оновлюємо координати, якщо вони змінилися.
    if (order.StartingCoordinates.X != request.StartLongitude!.Value ||
        order.StartingCoordinates.Y != request.StartLatitude!.Value)
    {
        order.StartingCoordinates = new Point(
            request.StartLongitude.Value,
            request.StartLatitude.Value)
        {
            SRID = 4326
        };
    }

    if (order.EndCoordinates.X != request.EndLongitude!.Value ||
        order.EndCoordinates.Y != request.EndLatitude!.Value)
    {
        order.EndCoordinates = new Point(
            request.EndLongitude.Value,
            request.EndLatitude.Value)
        {
            SRID = 4326
        };
    }

    // Оновлюємо інші поля.
    order.DepartureTimeAtUtc =
        request.DepartureTimeAtUtc!.Value.UtcDateTime;

    order.AvailableMaxWeight = request.AvailableMaxWeight;
    order.AvailableMaxLength = request.AvailableMaxLength;
    order.AvailableMaxDepth = request.AvailableMaxDepth;
    order.AvailableMaxHeight = request.AvailableMaxHeight;

    order.MinRewardReceived = request.MinRewardReceived;
    order.MaxRewardReceived = request.MaxRewardReceived;

    await _db.SaveChangesAsync(cancellationToken);

    var result = await GetByIdAsync(
        userId,
        orderId,
        cancellationToken);

    await transaction.CommitAsync(cancellationToken);

    return result;
    }
    
    public async Task<DelivererOrderResponse?> CancelAsync(
        long userId,
        long orderId,
        CancellationToken cancellationToken = default)
    {
        await using var transaction =
            await _db.Database.BeginTransactionAsync(cancellationToken);

        await AcquireOrderLockAsync(
            orderId,
            cancellationToken);

        // Перевіряємо існування та власника замовлення.
        var order = await _db.DelivererIntents
            .FirstOrDefaultAsync(
                x => x.DelivererIntentId == orderId &&
                     x.AuthorDelivererUserId == userId,
                cancellationToken);

        if (order is null)
        {
            return null;
        }

        // Повторне скасування не змінює стан замовлення.
        if (order.OrderStatusCode == "Cancelled")
        {
            var existing = await GetByIdAsync(
                userId,
                orderId,
                cancellationToken);

            await transaction.CommitAsync(cancellationToken);

            return existing;
        }

        var details = await _db.DelivererIntentDetails
            .FirstAsync(
                x => x.DelivererIntentId == orderId,
                cancellationToken);

        // Активні або виконані угоди забороняють скасування.
        if (details.ActiveDealCount > 0 ||
            details.FulfilledDealCount > 0)
        {
            throw new OrderUpdateConflictException(
                "Order has an active or fulfilled deal.");
        }

        // Тимчасове обмеження до узгодження
        // механізму закриття пов'язаних взаємодій.
        if (details.TotalInteractionCount > 0)
        {
            throw new OrderUpdateConflictException(
                "Order has related interactions.");
        }

        order.OrderStatusCode = "Cancelled";

        await _db.SaveChangesAsync(cancellationToken);

        var result = await GetByIdAsync(
            userId,
            orderId,
            cancellationToken);

        await transaction.CommitAsync(cancellationToken);

        return result;
    }
    
    public async Task<DelivererOrderSearchPage> SearchAsync(
        long userId,
        int page,
        int pageSize,
        CancellationToken cancellationToken = default)
    {
        var orders = await _db.DelivererIntentDetails
            .AsNoTracking()
            .Where(x =>
                x.IsAvailableAsTarget == true &&
                x.AuthorDelivererUserId != userId)
            .OrderByDescending(x => x.CreatedAtUtc)
            .ThenByDescending(x => x.DelivererIntentId)
            .Skip((page - 1) * pageSize)
            .Take(pageSize + 1)
            .ToListAsync(cancellationToken);

        var hasMore = orders.Count > pageSize;

        var items = orders
            .Take(pageSize)
            .Select(x => new DelivererOrderSearchResponse(
                x.DelivererIntentId,

                x.StartingCoordinates.Y,
                x.StartingCoordinates.X,

                x.EndCoordinates.Y,
                x.EndCoordinates.X,

                DateTime.SpecifyKind(
                    x.DepartureTimeAtUtc,
                    DateTimeKind.Utc),

                x.AvailableMaxWeight,
                x.AvailableMaxLength,
                x.AvailableMaxDepth,
                x.AvailableMaxHeight,

                x.MinRewardReceived,
                x.MaxRewardReceived
            ))
            .ToList();

        return new DelivererOrderSearchPage(
            items,
            page,
            pageSize,
            hasMore
        );
    }
    
    
    private async Task AcquireOrderLockAsync(
        long orderId,
        CancellationToken cancellationToken)
    {
        var resource = FormattableString.Invariant(
            $"PassBy:Intent:D:{orderId}");

        await _db.Database.ExecuteSqlInterpolatedAsync($@"
        DECLARE @LockResult INT;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = {resource},
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @DbPrincipal = 'public',
            @LockTimeout = 10000;

        IF @LockResult IN (-1, -2, -3)
            THROW 51990, N'Failed to lock deliverer order.', 1;

        IF @LockResult < 0
            THROW 51991, N'Order lock error.', 1;
    ", cancellationToken);
    }
}