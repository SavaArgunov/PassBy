using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace PassByBack.DTO.Verification;

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ValidateDocumentRequest(
    [Required, StringLength(64)] string ProviderCode,
    [Required, StringLength(512)] string DocumentReference);

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record VerifyIdentityRequest(
    [Range(typeof(long), "1", "9223372036854775807")] long DocumentId,
    [Required, StringLength(128)] string Proof);

public sealed record DocumentSummary(long DocumentId, string ProviderCode, DateTime ValidatedAtUtc);

public sealed record DocumentList(IReadOnlyList<DocumentSummary> Documents);

public sealed record IdCardDetails(string GivenName, string FamilyName, DateOnly BirthDate, DateOnly ExpiresAt);

public sealed record DocumentDetails(
    long DocumentId,
    string DocumentType,
    string ProviderCode,
    DateTime ValidatedAtUtc,
    IdCardDetails IdCard);

public sealed record VerificationAttempt(
    long VerificationId,
    long DocumentId,
    string VerificationCode,
    DateTime CheckedAtUtc,
    DateTime? ValidUntilUtc);

public sealed record VerificationStatus(VerificationAttempt? LastAttempt);
