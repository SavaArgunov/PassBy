using System.Net;
using Microsoft.Data.SqlClient;

namespace PassByBack.Services.Verification;

public sealed record VerificationSettings(bool MockBankEnabled, TimeSpan SuccessValidity)
{
    public static bool UsesLocalDatabase(string? connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            return false;
        }

        var connection = new SqlConnectionStringBuilder(connectionString);
        if (!string.Equals(connection.InitialCatalog, "PassBy", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var source = connection.DataSource.Trim();
        if (source.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase))
        {
            source = source[4..];
        }

        var host = source.Split(',', 2)[0];
        return host.Equals("db", StringComparison.OrdinalIgnoreCase) ||
               host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
               (IPAddress.TryParse(host, out var address) && IPAddress.IsLoopback(address));
    }

    public static bool UsesAzureTestDatabase(
        string? connectionString,
        string? expectedServer,
        string? expectedDatabase)
    {
        if (string.IsNullOrWhiteSpace(connectionString) ||
            string.IsNullOrWhiteSpace(expectedServer) ||
            string.IsNullOrWhiteSpace(expectedDatabase))
        {
            return false;
        }

        var connection = new SqlConnectionStringBuilder(connectionString);

        return string.Equals(connection.DataSource.Trim(), expectedServer.Trim(),
                   StringComparison.OrdinalIgnoreCase) &&
               string.Equals(connection.InitialCatalog, expectedDatabase.Trim(),
                   StringComparison.OrdinalIgnoreCase);
    }
}
