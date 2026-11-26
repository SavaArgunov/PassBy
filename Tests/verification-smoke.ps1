#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repo 'docker-compose.dev.yml'
$apiUrl = 'http://127.0.0.1:8080'

function Assert-Check($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

Add-Type -AssemblyName System.Net.Http
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(15)

function Invoke-Api([string]$Method, [string]$Path, [int]$Expected, $Body, [string]$Token, [string]$Key) {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), ($apiUrl + $Path))
    try {
        if ($Token) { $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
        if ($Key) { $request.Headers.Add('Idempotency-Key', $Key) }
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Compress
            $request.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            Assert-Check ([int]$response.StatusCode -eq $Expected) "$Method $Path returned $([int]$response.StatusCode), expected $Expected"
            if ($response.Content -and $response.Content.Headers.ContentType.MediaType -match 'json') {
                return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
            }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Invoke-LocalSql([string]$Sql) {
    $query = ("SET NOCOUNT ON; $Sql").Replace("'", "'\''")
    $command = 'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; printf ''%s\n'' ''{0}'' | /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d PassBy -h -1 -W -i /dev/stdin' -f $query
    $lines = ($command + "`n#") | & docker compose -f $compose exec -T db sh -s
    if ($LASTEXITCODE -ne 0) { throw 'Local Docker SQL command failed.' }
    return ($lines -join "`n").Trim()
}

function New-TestAccount([string]$Email) {
    $password = 'PassBy-local-' + [Guid]::NewGuid().ToString('N')
    $account = Invoke-Api POST '/api/auth/register' 201 @{
        emailAddress = $Email; password = $password; phoneNumber = '+380000000000'
    }
    $login = Invoke-Api POST '/api/auth/login' 200 @{ emailAddress = $Email; password = $password }
    return @{ UserId = [long]$account.userId; Email = $Email; Password = $password; Token = $login.accessToken }
}

# Check the running API container before any test can write to it.
$localConfig = 'case "$ConnectionStrings__DefaultConnection" in "Server=db;"*|"Server=db,1433;"*) ;; *) exit 1 ;; esac; case "$ConnectionStrings__DefaultConnection" in *";Database=PassBy;"*) ;; *) exit 1 ;; esac; test "$Verification__MockBank__Enabled" = true'
($localConfig + "`n#") | & docker compose -f $compose exec -T api sh -s
Assert-Check ($LASTEXITCODE -eq 0) 'Start the local Compose API with MockBank enabled before running these tests.'
$port = & docker compose -f $compose port api 8080
Assert-Check ($LASTEXITCODE -eq 0 -and ($port -match ':8080$')) 'The local Compose API must publish port 8080.'
$schema = Invoke-LocalSql "SELECT CASE WHEN COL_LENGTH(N'dbo.IdentityVerification', N'requestId') IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.VerificationProvider WHERE providerCode = 'MockBank' AND isEnabled = 1) THEN 'ready' ELSE 'missing' END;"
Assert-Check ($schema -eq 'ready') 'Run the local Compose db-init service first.'
$null = Invoke-Api GET '/api/health/db' 200

$api = '/api/verification'
$sample = @{
    providerCode = 'MockBank'
    documentReference = 'TEST-ID-' + (Get-Random -Minimum 100000000 -Maximum 999999999)
}
$validProof = $sample.documentReference.Replace('TEST-ID-', 'DEMO-PROOF-')
$null = Invoke-Api POST "$api/documents/validate" 401 $sample
$null = Invoke-Api GET "$api/documents" 401
$null = Invoke-Api GET "$api/documents/1" 401
$null = Invoke-Api POST "$api/attempts" 401 @{ documentId = 1; proof = $validProof }
$null = Invoke-Api GET "$api/status" 401

$tag = [Guid]::NewGuid().ToString('N')
$owner = New-TestAccount "passby-$tag-owner@example.invalid"
$other = New-TestAccount "passby-$tag-other@example.invalid"
$empty = Invoke-Api GET "$api/status" 200 -Token $owner.Token
Assert-Check ($null -eq $empty.lastAttempt -and 'isVerified' -notin $empty.PSObject.Properties.Name) 'Expected empty historical status.'

$null = Invoke-Api POST "$api/documents/validate" 400 @{
    providerCode = 'MockBank'; documentReference = 'TEST-ID-000'
} $owner.Token
$list = Invoke-Api GET "$api/documents" 200 -Token $owner.Token
Assert-Check ($list.documents.Count -eq 0) 'Rejected validation created a document.'

$document = Invoke-Api POST "$api/documents/validate" 201 $sample $owner.Token
$documentId = [long]$document.documentId
$replay = Invoke-Api POST "$api/documents/validate" 200 $sample $owner.Token
Assert-Check ($replay.documentId -eq $documentId) 'Repeated validation changed the document ID.'
$null = Invoke-Api POST "$api/documents/validate" 409 $sample $other.Token
$list = Invoke-Api GET "$api/documents" 200 -Token $owner.Token
Assert-Check ($list.documents.Count -eq 1 -and $list.documents[0].documentId -eq $documentId) 'Expected exactly one document for the owner.'
$details = Invoke-Api GET "$api/documents/$documentId" 200 -Token $owner.Token
Assert-Check ($details.documentType -eq 'IDCard' -and $details.idCard.givenName) 'Expected persisted ID card details.'
Assert-Check ('photoReference' -notin $details.idCard.PSObject.Properties.Name -and
    'documentReference' -notin $details.PSObject.Properties.Name) 'Document response disclosed extra fields.'
$null = Invoke-Api GET "$api/documents/$documentId" 404 -Token $other.Token
$null = Invoke-Api POST "$api/attempts" 404 @{
    documentId = $documentId; proof = $validProof
} $other.Token ([Guid]::NewGuid())
$null = Invoke-Api POST "$api/attempts" 400 @{ documentId = $documentId; verificationCode = 'Succeeded' } $owner.Token ([Guid]::NewGuid())
$null = Invoke-Api POST "$api/attempts" 400 @{ documentId = $documentId; proof = $validProof } $owner.Token

$key = [Guid]::NewGuid()
$body = @{ documentId = $documentId; proof = $validProof }
$success = Invoke-Api POST "$api/attempts" 201 $body $owner.Token $key
Assert-Check ($success.verificationCode -eq 'Succeeded' -and
    [DateTimeOffset]$success.validUntilUtc -gt [DateTimeOffset]$success.checkedAtUtc) 'Successful attempt has no valid interval.'
$same = Invoke-Api POST "$api/attempts" 200 $body $owner.Token $key
Assert-Check ($same.verificationId -eq $success.verificationId) 'Attempt replay created a duplicate.'
$failure = Invoke-Api POST "$api/attempts" 201 @{ documentId = $documentId; proof = 'DEMO-WRONG' } $owner.Token ([Guid]::NewGuid())
Assert-Check ($failure.verificationCode -eq 'IdentityMismatch' -and $null -eq $failure.validUntilUtc -and
    $failure.verificationId -ne $success.verificationId) 'Expected a separate mismatch without a validity interval.'
$status = Invoke-Api GET "$api/status" 200 -Token $owner.Token
Assert-Check ($status.lastAttempt.verificationId -eq $failure.verificationId) 'Status did not return the latest completed attempt.'

$cards = Invoke-LocalSql "SELECT COUNT(*) FROM dbo.IDCardData AS c JOIN dbo.ValidatedDocument AS d ON c.documentId = d.documentId WHERE d.documentId = $documentId AND d.userId = $($owner.UserId);"
Assert-Check ($cards -eq '1') 'Expected exactly one ID card for the document in SQL.'
$attemptCount = Invoke-LocalSql "SELECT CONCAT(COUNT(*), ':', SUM(CASE WHEN verificationCode = 'Succeeded' AND validUntilUtc IS NOT NULL THEN 1 ELSE 0 END)) FROM dbo.IdentityVerification WHERE documentId = $documentId;"
Assert-Check ($attemptCount -eq '2:1') 'SQL history lost a completed attempt or inserted a duplicate.'

# A role must become available on the same JWT, and then blocking must revoke that JWT.
$null = Invoke-Api GET '/api/roles/check/deliverer' 403 -Token $owner.Token
$null = Invoke-Api POST '/api/roles/acquire' 200 @{ role = 'Deliverer' } $owner.Token
$null = Invoke-Api GET '/api/roles/check/deliverer' 200 -Token $owner.Token
$null = Invoke-Api GET '/api/roles' 200 -Token $owner.Token
$null = Invoke-LocalSql "UPDATE dbo.UserAccount SET isBlocked = 1 WHERE userId = $($owner.UserId);"
$null = Invoke-Api GET '/api/roles' 401 -Token $owner.Token
$null = Invoke-Api GET '/api/roles/check/deliverer' 401 -Token $owner.Token
$null = Invoke-Api GET "$api/status" 401 -Token $owner.Token
$null = Invoke-Api POST '/api/auth/login' 403 @{ emailAddress = $owner.Email; password = $owner.Password }

Write-Output 'PassBy verification smoke tests passed. Synthetic records remain in local Docker SQL.'
