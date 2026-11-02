using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace PassByBack.Authorization;

public class SqlRoleStore : IRoleStore
{
    private const string AccountRolesSql = @"
SELECT a.isBlocked,
       r.registeredAtUtc, r.isBlocked,
       d.registeredAtUtc, d.isBlocked
FROM dbo.UserAccount AS a
LEFT JOIN dbo.DeliveryRequester AS r ON r.userId = a.userId
LEFT JOIN dbo.Deliverer AS d ON d.userId = a.userId
WHERE a.userId = @userId;";

    private readonly string _connectionString;

    public SqlRoleStore(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("PassBy")
            ?? throw new InvalidOperationException("Connection string 'PassBy' is missing");
    }

    public async Task<AccountRoles?> GetAccountRolesAsync(
        long userId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(AccountRolesSql, connection);
        command.Parameters.Add("@userId", SqlDbType.BigInt).Value = userId;

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        var roles = new List<RoleRecord>();

        if (!reader.IsDBNull(1))
        {
            roles.Add(new RoleRecord(
                AppRoles.DeliveryRequester,
                reader.GetDateTime(1),
                reader.GetBoolean(2)));
        }

        if (!reader.IsDBNull(3))
        {
            roles.Add(new RoleRecord(
                AppRoles.Deliverer,
                reader.GetDateTime(3),
                reader.GetBoolean(4)));
        }

        return new AccountRoles(userId, reader.GetBoolean(0), roles);
    }

    public async Task<bool> AddRoleAsync(
        long userId,
        string roleName,
        CancellationToken cancellationToken = default)
    {
        // Назва таблиці береться лише з цього списку, а не зі вводу користувача.
        var table = roleName switch
        {
            AppRoles.DeliveryRequester => "dbo.DeliveryRequester",
            AppRoles.Deliverer => "dbo.Deliverer",
            _ => throw new ArgumentException($"Unknown role '{roleName}'", nameof(roleName))
        };

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = new SqlCommand(
            $"INSERT INTO {table} (userId, registeredAtUtc, isBlocked) " +
            "VALUES (@userId, @registeredAtUtc, 0);",
            connection);

        command.Parameters.Add("@userId", SqlDbType.BigInt).Value = userId;
        command.Parameters.Add("@registeredAtUtc", SqlDbType.DateTime2).Value = DateTime.UtcNow;

        try
        {
            await command.ExecuteNonQueryAsync(cancellationToken);
            return true;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            // Порушення первинного ключа: роль уже є (наприклад, паралельний запит)
            return false;
        }
    }
}
