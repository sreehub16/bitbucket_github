<#
.SYNOPSIS
    Bitbucket Server pre-migration readiness check for GitHub migrations.

.DESCRIPTION
    Reads a CSV file of Bitbucket Server repositories and checks each one
    for open pull requests. Produces a timestamped output CSV reporting
    which repos are ready to migrate.

    Required CSV columns : project-key, repo
    Optional CSV columns : project-name, is-archived

    Required environment variables:
        BBS_BASE_URL   - Base URL of the Bitbucket Server instance
                         e.g. https://bitbucket.example.com

    Authentication (one of the following):
        BBS_PAT        - Personal Access Token 
        (or)
        BBS_AUTH_TYPE  - Set to "Basic", combined with:
        BBS_USERNAME   - Bitbucket username
        BBS_PASSWORD   - Bitbucket password

.PARAMETER CsvPath
    Path to the input CSV file. Defaults to repos.csv in the current directory.

.PARAMETER OutputPath
    Path for the output CSV report.
    Defaults to bbs_pr_validation_output-<timestamp>.csv

.EXAMPLE
    $env:BBS_PAT      = "your-token" 
    (or)
    $env:BBS_USERNAME   - Bitbucket username
    $env:BBS_PASSWORD   - Bitbucket password
    $env:BBS_BASE_URL = "https://bitbucket.example.com"
    .\0_prechecks.ps1

.EXAMPLE
    .\0_prechecks.ps1 -CsvPath "C:\migrations\repos.csv" -OutputPath "C:\migrations\results.csv"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "repos.csv",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

#region ── Environment validation ────────────────────────────────────────────

if (-not $env:BBS_BASE_URL) {
    Write-Host "[ERROR] BBS_BASE_URL environment variable is not set." -ForegroundColor Red
    Write-Host "        Set it by running: `$env:BBS_BASE_URL = 'https://bitbucket.example.com'" -ForegroundColor Yellow
    exit 1
}
$BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')

#endregion

#region ── CSV validation ─────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Host "[ERROR] CSV file not found: $CsvPath" -ForegroundColor Red
    Write-Host "        Usage: .\0_prechecks.ps1 -CsvPath 'path\to\repos.csv'" -ForegroundColor Yellow
    exit 1
}

if ((Get-Item -LiteralPath $CsvPath).Length -eq 0) {
    Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
    exit 1
}

$rawCsv    = (Get-Content -LiteralPath $CsvPath -Raw) -replace '"', ''
$csvLines  = $rawCsv -split "`r?`n" | Where-Object { $_ -ne '' }
$headerColumns = $csvLines[0] -split ','

if ($headerColumns -notcontains 'project-key' -or $headerColumns -notcontains 'repo') {
    Write-Host "[ERROR] CSV is missing required columns. Expected: project-key, repo" -ForegroundColor Red
    Write-Host "        Found header: $($csvLines[0])" -ForegroundColor Yellow
    exit 1
}

$repoList = @(Import-Csv -LiteralPath $CsvPath)

if ($repoList.Count -eq 0) {
    Write-Host "[ERROR] CSV contains no data rows." -ForegroundColor Red
    exit 1
}

#endregion

#region ── Auth ───────────────────────────────────────────────────────────────

function Get-AuthHeader {
    if ($env:BBS_PAT) {
        return @{ Authorization = "Bearer $($env:BBS_PAT)" }
    }
    elseif (($env:BBS_AUTH_TYPE -eq 'Basic') -and $env:BBS_USERNAME -and $env:BBS_PASSWORD) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$($env:BBS_USERNAME):$($env:BBS_PASSWORD)")
        $b64   = [Convert]::ToBase64String($bytes)
        return @{ Authorization = "Basic $b64" }
    }
    else {
        Write-Host "[ERROR] No valid credentials found." -ForegroundColor Red
        Write-Host "        Provide BBS_PAT, or set BBS_AUTH_TYPE=Basic with BBS_USERNAME and BBS_PASSWORD." -ForegroundColor Yellow
        exit 1
    }
}

function Invoke-BbsApi {
    param([string]$Url)
    try {
        return Invoke-RestMethod -Uri $Url -Headers (Get-AuthHeader) -Method Get -ErrorAction Stop
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $msg = if ($status) { "HTTP $status" } else { $_.Exception.Message }
        throw "API call failed ($msg): $Url"
    }
}

Write-Host "`nValidating credentials against $BASE_URL ..."
try {
    $null = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects?limit=1"
    Write-Host "v Authentication successful." -ForegroundColor Green
}
catch {
    Write-Host "x Authentication failed. Verify BBS_BASE_URL and credentials." -ForegroundColor Red
    Write-Host "  Detail: $_" -ForegroundColor Red
    exit 1
}

#endregion

#region ── Functions ──────────────────────────────────────────────────────────

function Get-OpenPrCount {
    param(
        [string]$ProjectKey,
        [string]$RepoSlug
    )
    $start = 0
    $total = 0
    do {
        $resp   = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/pull-requests?state=OPEN&limit=100&start=$start"
        $total += $resp.values.Count
        $isLast = $resp.isLastPage
        if (-not $isLast) {
            if ($null -ne $resp.nextPageStart) { $start = [int]$resp.nextPageStart }
            else { break }
        }
    } while (-not $isLast)
    return $total
}

function ConvertTo-SafeBool {
    param([string]$Value)
    switch ($Value.Trim().ToLower()) {
        'true'  { return $true  }
        '1'     { return $true  }
        'yes'   { return $true  }
        default { return $false }
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host "`n Bitbucket Server Pre-Migration Readiness Check"
Write-Host "================================================"
Write-Host "`nReading input from file : '$CsvPath'"
Write-Host "Repos loaded            : $($repoList.Count)"

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutputCsv = if ($OutputPath) { $OutputPath } else { "bbs_pr_validation_output-$timestamp.csv" }

$csvHeader = "project_key,project_name,repo_name,is_archived,open_pr_count,warnings,ready_to_migrate"
Set-Content -LiteralPath $OutputCsv -Value $csvHeader -Encoding UTF8

$readyRepos     = New-Object System.Collections.Generic.List[string]
$prCheckFailed  = $false
$totalOpenPrs   = 0
$processedCount = 0

Write-Host "`nScanning repositories for open pull requests...`n"

foreach ($entry in $repoList) {
    $projectKey  = $entry.'project-key'
    $projectName = if ($entry.'project-name') { $entry.'project-name' } else { $entry.'project-key' }
    $repoSlug    = $entry.repo
    $isArchived  = ConvertTo-SafeBool -Value "$($entry.'is-archived')"

    $processedCount++
    $progress = "[$processedCount/$($repoList.Count)]"

    try {
        $openPrs      = Get-OpenPrCount -ProjectKey $projectKey -RepoSlug $repoSlug
        $totalOpenPrs += $openPrs
        $warnings     = if ($openPrs -gt 0) { "OPEN_PRS" } else { "" }
        $ready        = ($warnings -eq "")

        if ($ready) {
            Write-Host "[OK]      $progress $projectKey/$repoSlug  --  Open PRs: $openPrs" -ForegroundColor Green
            $readyRepos.Add("$projectKey/$repoSlug")
        }
        else {
            Write-Host "[WARNING] $progress $projectKey/$repoSlug  --  Open PRs: $openPrs" -ForegroundColor Yellow
        }

        $csvRow = "$projectKey,$projectName,$repoSlug,$isArchived,$openPrs,$warnings,$ready"
        Add-Content -LiteralPath $OutputCsv -Value $csvRow -Encoding UTF8
    }
    catch {
        $prCheckFailed = $true
        Write-Host "[ERROR]   $progress $projectKey/$repoSlug  --  $_" -ForegroundColor Red

        $csvRow = "$projectKey,$projectName,$repoSlug,$isArchived,ERROR,API_FAILURE,false"
        Add-Content -LiteralPath $OutputCsv -Value $csvRow -Encoding UTF8
    }
}

#endregion

#region ── Summary ────────────────────────────────────────────────────────────

$hasActiveItems = $totalOpenPrs -gt 0
$hasFailures    = $prCheckFailed

if ($hasFailures -and -not $hasActiveItems) {
    $finalMessage = "Validation could not be completed due to API failures. Review errors before proceeding."
    $finalColor   = "Red"
}
elseif ($hasFailures -and $hasActiveItems) {
    $finalMessage = "Open PRs detected, but some checks also failed. Review warnings and errors before proceeding."
    $finalColor   = "Yellow"
}
elseif (-not $hasFailures -and $hasActiveItems) {
    $finalMessage = "Open pull requests found. Review and resolve them before proceeding with migration."
    $finalColor   = "Yellow"
}
else {
    $finalMessage = "No open pull requests detected. You can proceed with migration."
    $finalColor   = "Green"
}

Write-Host "`nPre-Migration Validation Summary"
Write-Host "================================"
Write-Host "[SUMMARY] Total repos    : $processedCount"
Write-Host "[SUMMARY] Repos ready    : $($readyRepos.Count)"
Write-Host "[SUMMARY] Total open PRs : $totalOpenPrs"
Write-Host "[SUMMARY] Output CSV     : $OutputCsv"
Write-Host "`n$finalMessage`n" -ForegroundColor $finalColor

#endregion
