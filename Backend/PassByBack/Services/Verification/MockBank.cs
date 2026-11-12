namespace PassByBack.Services.Verification;

public sealed record MockIdCard(
    string GivenName, string FamilyName, DateOnly BirthDate, DateOnly ExpiresAt, string PhotoReference);

public enum MockIdentityMatch
{
    Matched,
    Mismatch,
    Expired
}

public sealed class MockBank
{
    public const string ProviderCode = "MockBank";
    private const string DocumentPrefix = "TEST-ID-";

    public MockIdCard? ValidateDocument(string reference)
    {
        if (FixtureNumber(reference) is null)
        {
            return null;
        }

        return new MockIdCard("Тестова", "Особа", new DateOnly(2000, 1, 1),
            new DateOnly(2099, 12, 31), "mock:no-photo");
    }

    public MockIdentityMatch MatchIdentity(string reference, DateOnly expiresAt, string proof, DateOnly today)
    {
        if (expiresAt < today)
        {
            return MockIdentityMatch.Expired;
        }

        var number = FixtureNumber(reference);
        return number is not null && string.Equals(proof, $"DEMO-PROOF-{number}", StringComparison.Ordinal)
            ? MockIdentityMatch.Matched
            : MockIdentityMatch.Mismatch;
    }

    private static string? FixtureNumber(string reference)
    {
        if (!reference.StartsWith(DocumentPrefix, StringComparison.Ordinal))
        {
            return null;
        }

        var number = reference[DocumentPrefix.Length..];
        return number.Length is >= 3 and <= 9 &&
               number.All(char.IsAsciiDigit) &&
               number.Any(digit => digit != '0')
            ? number
            : null;
    }
}
