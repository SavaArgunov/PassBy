using System.Globalization;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using PassByBack.DTO.Verification;
using PassByBack.Services.Verification;

namespace PassByBack.Controllers;

[ApiController]
[Authorize]
[Route("api/verification")]
[ResponseCache(NoStore = true, Location = ResponseCacheLocation.None)]
public sealed class VerificationController(VerificationService verification) : ControllerBase
{
    private long UserId => long.Parse(User.FindFirstValue(JwtRegisteredClaimNames.Sub)!, CultureInfo.InvariantCulture);

    [HttpPost("documents/validate")]
    public async Task<IActionResult> ValidateDocument(
        ValidateDocumentRequest request, CancellationToken cancellationToken)
    {
        try
        {
            var (document, created) = await verification.ValidateDocumentAsync(UserId, request, cancellationToken);
            return created ? CreatedAtAction(nameof(GetDocument), new { documentId = document.DocumentId }, document)
                : Ok(document);
        }
        catch (VerificationRequestException ex)
        {
            return VerificationError(ex.Problem);
        }
    }

    [HttpGet("documents")]
    public Task<DocumentList> GetDocuments(CancellationToken cancellationToken) =>
        verification.GetDocumentsAsync(UserId, cancellationToken);

    [HttpGet("documents/{documentId:long:min(1)}")]
    public async Task<IActionResult> GetDocument(long documentId, CancellationToken cancellationToken)
    {
        var document = await verification.GetDocumentAsync(UserId, documentId, cancellationToken);
        return document is null ? VerificationError(VerificationProblem.DocumentNotFound) : Ok(document);
    }

    [HttpPost("attempts")]
    public async Task<IActionResult> VerifyIdentity(
        VerifyIdentityRequest request,
        [FromHeader(Name = "Idempotency-Key")] Guid? requestId,
        CancellationToken cancellationToken)
    {
        if (requestId is null || requestId == Guid.Empty)
        {
            return BadRequest(new { message = "Заголовок Idempotency-Key має містити непорожній UUID." });
        }

        try
        {
            var (attempt, created) = await verification.VerifyIdentityAsync(UserId, request, requestId.Value,
                cancellationToken);
            return StatusCode(created ? StatusCodes.Status201Created : StatusCodes.Status200OK, attempt);
        }
        catch (VerificationRequestException ex)
        {
            return VerificationError(ex.Problem);
        }
    }

    [HttpGet("status")]
    public Task<VerificationStatus> GetStatus(CancellationToken cancellationToken) =>
        verification.GetStatusAsync(UserId, cancellationToken);

    private ObjectResult VerificationError(VerificationProblem problem)
    {
        var (status, message) = problem switch
        {
            VerificationProblem.InvalidDocument => (400, "MockBank не прийняв дані документа."),
            VerificationProblem.DocumentNotFound => (404, "Документ не знайдено."),
            VerificationProblem.DocumentConflict => (409, "Цей документ неможливо додати."),
            _ => (503, "Перевірка MockBank зараз недоступна.")
        };

        return StatusCode(status, new { message });
    }
}
