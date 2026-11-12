using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using PassByBack.Data;
using PassByBack.DTO.Verification;
using PassByBack.Models.Entities;

namespace PassByBack.Services.Verification;

public enum VerificationProblem
{
    InvalidDocument,
    DocumentNotFound,
    DocumentConflict,
    ProviderUnavailable
}

public sealed class VerificationRequestException(VerificationProblem problem) : Exception
{
    public VerificationProblem Problem { get; } = problem;
}

public sealed class VerificationService(AppDbContext db, MockBank mockBank, VerificationSettings settings)
{
    public async Task<(DocumentSummary Document, bool Created)> ValidateDocumentAsync(
        long userId, ValidateDocumentRequest request, CancellationToken cancellationToken)
    {
        if (!string.Equals(request.ProviderCode.Trim(), MockBank.ProviderCode, StringComparison.Ordinal))
        {
            throw new VerificationRequestException(VerificationProblem.InvalidDocument);
        }

        if (!settings.MockBankEnabled)
        {
            throw new VerificationRequestException(VerificationProblem.ProviderUnavailable);
        }

        var provider = await db.VerificationProviders.AsNoTracking()
            .SingleOrDefaultAsync(x => x.ProviderCode == MockBank.ProviderCode && x.IsEnabled, cancellationToken);
        if (provider is null)
        {
            throw new VerificationRequestException(VerificationProblem.ProviderUnavailable);
        }

        var reference = request.DocumentReference.Trim();
        var card = mockBank.ValidateDocument(reference)
            ?? throw new VerificationRequestException(VerificationProblem.InvalidDocument);

        var existing = await FindExistingDocumentAsync(provider, reference, userId, cancellationToken);
        if (existing is not null)
        {
            return (existing, false);
        }

        var document = new ValidatedDocument
        {
            DocumentReference = reference,
            VerificationProviderId = provider.ProviderId,
            UserId = userId,
            ValidatedAtUtc = DateTime.UtcNow,
            IdCard = new IDCardData
            {
                GivenName = card.GivenName,
                FamilyName = card.FamilyName,
                BirthDate = card.BirthDate,
                ExpiresAt = card.ExpiresAt,
                PhotoReference = card.PhotoReference
            }
        };

        db.ValidatedDocuments.Add(document);
        try
        {
            await db.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateException ex) when (ex.InnerException is SqlException { Number: 2601 or 2627 })
        {
            db.Entry(document.IdCard!).State = EntityState.Detached;
            db.Entry(document).State = EntityState.Detached;
            existing = await FindExistingDocumentAsync(provider, reference, userId, cancellationToken);
            if (existing is null)
            {
                throw;
            }

            return (existing, false);
        }

        return (new DocumentSummary(document.DocumentId, provider.ProviderCode, document.ValidatedAtUtc), true);
    }

    public async Task<DocumentList> GetDocumentsAsync(long userId, CancellationToken cancellationToken)
    {
        var documents = await db.ValidatedDocuments.AsNoTracking()
            .Where(x => x.UserId == userId)
            .OrderByDescending(x => x.ValidatedAtUtc)
            .ThenByDescending(x => x.DocumentId)
            .Select(x => new DocumentSummary(x.DocumentId, x.Provider.ProviderCode, x.ValidatedAtUtc))
            .ToListAsync(cancellationToken);

        return new DocumentList(documents);
    }

    public Task<DocumentDetails?> GetDocumentAsync(
        long userId, long documentId, CancellationToken cancellationToken) =>
        db.ValidatedDocuments.AsNoTracking()
            .Where(x => x.UserId == userId && x.DocumentId == documentId && x.IdCard != null)
            .Select(x => new DocumentDetails(
                x.DocumentId, "IDCard", x.Provider.ProviderCode, x.ValidatedAtUtc,
                new IdCardDetails(x.IdCard!.GivenName, x.IdCard!.FamilyName, x.IdCard!.BirthDate, x.IdCard!.ExpiresAt)))
            .SingleOrDefaultAsync(cancellationToken);

    public async Task<(VerificationAttempt Attempt, bool Created)> VerifyIdentityAsync(
        long userId, VerifyIdentityRequest request, Guid requestId, CancellationToken cancellationToken)
    {
        var document = await db.ValidatedDocuments.AsNoTracking()
            .Where(x => x.UserId == userId && x.DocumentId == request.DocumentId && x.IdCard != null)
            .Select(x => new { x.DocumentReference, ExpiresAt = x.IdCard!.ExpiresAt, x.Provider.ProviderCode, x.Provider.IsEnabled })
            .SingleOrDefaultAsync(cancellationToken);

        if (document is null)
        {
            throw new VerificationRequestException(VerificationProblem.DocumentNotFound);
        }

        if (!settings.MockBankEnabled || document.ProviderCode != MockBank.ProviderCode)
        {
            throw new VerificationRequestException(VerificationProblem.ProviderUnavailable);
        }

        var existing = await FindAttemptAsync(request.DocumentId, requestId, cancellationToken);
        if (existing is not null)
        {
            return (existing, false);
        }

        if (!document.IsEnabled)
        {
            throw new VerificationRequestException(VerificationProblem.ProviderUnavailable);
        }

        var now = DateTime.UtcNow;
        var match = mockBank.MatchIdentity(document.DocumentReference, document.ExpiresAt,
            request.Proof.Trim(), DateOnly.FromDateTime(now));
        var code = match switch
        {
            MockIdentityMatch.Matched => "Succeeded",
            MockIdentityMatch.Expired => "DocumentExpired",
            _ => "IdentityMismatch"
        };

        if (!await db.VerificationOutcomes.AnyAsync(x => x.VerificationCode == code, cancellationToken))
        {
            throw new VerificationRequestException(VerificationProblem.ProviderUnavailable);
        }

        var attempt = new IdentityVerification
        {
            DocumentId = request.DocumentId,
            RequestId = requestId,
            VerificationCode = code,
            CheckedAtUtc = now,
            ValidUntilUtc = match == MockIdentityMatch.Matched ? now.Add(settings.SuccessValidity) : null
        };

        db.IdentityVerifications.Add(attempt);
        try
        {
            await db.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateException ex) when (ex.InnerException is SqlException { Number: 2601 or 2627 })
        {
            db.Entry(attempt).State = EntityState.Detached;
            existing = await FindAttemptAsync(request.DocumentId, requestId, cancellationToken);
            if (existing is null)
            {
                throw;
            }

            return (existing, false);
        }

        return (new VerificationAttempt(attempt.VerificationId, attempt.DocumentId, attempt.VerificationCode,
            attempt.CheckedAtUtc, attempt.ValidUntilUtc), true);
    }

    public async Task<VerificationStatus> GetStatusAsync(long userId, CancellationToken cancellationToken)
    {
        var lastAttempt = await db.IdentityVerifications.AsNoTracking()
            .Where(x => x.Document.UserId == userId)
            .OrderByDescending(x => x.CheckedAtUtc)
            .ThenByDescending(x => x.VerificationId)
            .Select(x => new VerificationAttempt(x.VerificationId, x.DocumentId, x.VerificationCode,
                x.CheckedAtUtc, x.ValidUntilUtc))
            .FirstOrDefaultAsync(cancellationToken);

        return new VerificationStatus(lastAttempt);
    }

    private async Task<DocumentSummary?> FindExistingDocumentAsync(
        VerificationProvider provider, string reference, long userId, CancellationToken cancellationToken)
    {
        var document = await db.ValidatedDocuments.AsNoTracking()
            .Where(x => x.VerificationProviderId == provider.ProviderId && x.DocumentReference == reference)
            .Select(x => new { x.DocumentId, x.UserId, x.ValidatedAtUtc, HasIdCard = x.IdCard != null })
            .SingleOrDefaultAsync(cancellationToken);

        if (document is null)
        {
            return null;
        }

        if (document.UserId != userId || !document.HasIdCard)
        {
            throw new VerificationRequestException(VerificationProblem.DocumentConflict);
        }

        return new DocumentSummary(document.DocumentId, provider.ProviderCode, document.ValidatedAtUtc);
    }

    private Task<VerificationAttempt?> FindAttemptAsync(
        long documentId, Guid requestId, CancellationToken cancellationToken) =>
        db.IdentityVerifications.AsNoTracking()
            .Where(x => x.DocumentId == documentId && x.RequestId == requestId)
            .Select(x => new VerificationAttempt(x.VerificationId, x.DocumentId, x.VerificationCode,
                x.CheckedAtUtc, x.ValidUntilUtc))
            .SingleOrDefaultAsync(cancellationToken);
}
