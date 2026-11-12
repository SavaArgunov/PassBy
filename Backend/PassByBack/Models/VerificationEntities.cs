namespace PassByBack.Models.Entities;

public sealed class VerificationProvider
{
    public long ProviderId { get; set; }
    public string ProviderCode { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
}

public sealed class VerificationOutcome
{
    public string VerificationCode { get; set; } = string.Empty;
}

public sealed class ValidatedDocument
{
    public long DocumentId { get; set; }
    public string DocumentReference { get; set; } = string.Empty;
    public DateTime ValidatedAtUtc { get; set; }
    public long VerificationProviderId { get; set; }
    public long UserId { get; set; }

    public VerificationProvider Provider { get; set; } = null!;
    public IDCardData? IdCard { get; set; }
}

public sealed class IDCardData
{
    public long DocumentId { get; set; }
    public string GivenName { get; set; } = string.Empty;
    public string FamilyName { get; set; } = string.Empty;
    public DateOnly BirthDate { get; set; }
    public DateOnly ExpiresAt { get; set; }
    public string PhotoReference { get; set; } = string.Empty;
}

public sealed class IdentityVerification
{
    public long VerificationId { get; set; }
    public long DocumentId { get; set; }
    public Guid? RequestId { get; set; }
    public DateTime CheckedAtUtc { get; set; }
    public DateTime? ValidUntilUtc { get; set; }
    public string VerificationCode { get; set; } = string.Empty;

    public ValidatedDocument Document { get; set; } = null!;
}
