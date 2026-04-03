<#
.SYNOPSIS
    Bitbucket Server to GitHub migration script.

.DESCRIPTION
    Reads a CSV file of Bitbucket Server repositories and migrates each one
    to GitHub using the GitHub CLI bbs2gh extension. Supports concurrent
    migrations and produces a timestamped output CSV with migration status.

    Required CSV columns : project-key, project-name, repo, github_org,
                           github_repo, gh_repo_visibility

    Required environment variables:
        $env:BBS_BASE_URL         = "https://bitbucket.example.com"
        $env:BBS_USERNAME         = "your-username"
        $env:BBS_PASSWORD         = "your-password"
        $env:SSH_USER             = "your-ssh-username"

    SSH key (set one of the following):
        $env:SSH_PRIVATE_KEY_PATH = "C:\keys\id_rsa"       # full absolute path to private key file
        $env:SSH_PRIVATE_KEY      = "-----BEGIN RSA..."    # full private key content

    Storage — set ONE of the following before running:

        Azure Blob Storage:
        $env:AZURE_STORAGE_CONNECTION_STRING = "your-connection-string"

        AWS S3:
        $env:AWS_ACCESS_KEY_ID     = "your-access-key"
        $env:AWS_SECRET_ACCESS_KEY = "your-secret-key"
        $env:AWS_BUCKET_NAME       = "your-bucket-name"    # also accepts AWS_S3_BUCKET or AWS_BUCKET
        $env:AWS_REGION            = "us-east-1"           # also accepts AWS_DEFAULT_REGION

        GitHub-owned storage (default):
        No storage variables needed — used automatically if neither Azure nor AWS is configured.

        Note: Setting both Azure and AWS variables at the same time will cause the script to exit with an error.

    Optional environment variables:
        $env:TARGET_API_URL       = "https://api.github.com"   # defaults to https://api.github.com
        $env:VERBOSE              = "1"                         # set to 1 to enable debug logging

.PARAMETER CsvPath
    Path to the input CSV file. Defaults to repos.csv in the current directory.

.PARAMETER OutputPath
    Path for the output CSV report.
    Defaults to repo_migration_output-<timestamp>.csv

.PARAMETER MaxConcurrent
    Number of concurrent migration jobs. Must be between 1 and 20. Defaults to 5.

.EXAMPLE
    $env:BBS_BASE_URL         = "https://bitbucket.example.com"
    $env:BBS_USERNAME         = "admin"
    $env:BBS_PASSWORD         = "password"
    $env:SSH_USER             = "git"
    $env:SSH_PRIVATE_KEY_PATH = "C:\keys\id_rsa"
    .\1_migration.ps1

.EXAMPLE
    $env:BBS_BASE_URL                    = "https://bitbucket.example.com"
    $env:BBS_USERNAME                    = "admin"
    $env:BBS_PASSWORD                    = "password"
    $env:SSH_USER                        = "git"
    $env:SSH_PRIVATE_KEY_PATH            = "C:\keys\id_rsa"
    $env:AZURE_STORAGE_CONNECTION_STRING = "DefaultEndpointsProtocol=https;AccountName=..."
    .\1_migration.ps1 -CsvPath "C:\migrations\repos.csv" -MaxConcurrent 5
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "repos.csv",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [int]$MaxConcurrent = 5
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = (Get-Location).Path
$VERBOSE    = $env:VERBOSE -eq '1'

function Write-VerboseLog {
    param([string]$Message)
    if ($VERBOSE) { Write-Host "[DEBUG] $Message" -ForegroundColor Cyan }
}

#region ── Parameter validation ──────────────────────────────────────────────

if ($MaxConcurrent -gt 20) {
    Write-Host "[ERROR] Maximum concurrent migrations ($MaxConcurrent) exceeds the allowed limit of 20." -ForegroundColor Red
    exit 1
}
if ($MaxConcurrent -lt 1) {
    Write-Host "[ERROR] MaxConcurrent must be at least 1." -ForegroundColor Red
    exit 1
}

#endregion

#region ── CSV validation ─────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Host "[ERROR] CSV file not found: $CsvPath" -ForegroundColor Red
    Write-Host "        Usage: .\1_migration.ps1 -CsvPath 'path\to\repos.csv'" -ForegroundColor Yellow
    exit 1
}

if ((Get-Item -LiteralPath $CsvPath).Length -eq 0) {
    Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
    exit 1
}

$rawCsv        = (Get-Content -LiteralPath $CsvPath -Raw) -replace "`r", ""
$csvLines      = $rawCsv -split "`n" | Where-Object { $_ -ne '' }
$headerColumns = $csvLines[0] -split ','

$requiredColumns = @('project-key', 'project-name', 'repo', 'github_org', 'github_repo', 'gh_repo_visibility')
$missingColumns  = $requiredColumns | Where-Object { $headerColumns -notcontains $_ }

if ($missingColumns.Count -gt 0) {
    Write-Host "[ERROR] CSV is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host "        Found header: $($csvLines[0])" -ForegroundColor Yellow
    exit 1
}

$repoList = @(Import-Csv -LiteralPath $CsvPath)

if ($repoList.Count -eq 0) {
    Write-Host "[ERROR] CSV contains no data rows." -ForegroundColor Red
    exit 1
}

#endregion

#region ── Environment validation ────────────────────────────────────────────

if (-not $env:BBS_BASE_URL -or -not $env:BBS_USERNAME -or -not $env:BBS_PASSWORD) {
    Write-Host "[ERROR] BBS_BASE_URL, BBS_USERNAME, and BBS_PASSWORD must all be set." -ForegroundColor Red
    exit 1
}
$BBS_BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')
Write-VerboseLog "Using BBS_BASE_URL=$BBS_BASE_URL"

if (-not $env:SSH_USER) {
    Write-Host "[ERROR] SSH_USER environment variable must be set." -ForegroundColor Red
    exit 1
}

if (-not $env:SSH_PRIVATE_KEY_PATH -and -not $env:SSH_PRIVATE_KEY) {
    Write-Host "[ERROR] Provide SSH_PRIVATE_KEY_PATH (file path) or SSH_PRIVATE_KEY (key content)." -ForegroundColor Red
    exit 1
}

if ($env:SSH_PRIVATE_KEY_PATH -and -not (Test-Path -LiteralPath $env:SSH_PRIVATE_KEY_PATH)) {
    Write-Host "[ERROR] SSH private key file not found: $($env:SSH_PRIVATE_KEY_PATH)" -ForegroundColor Red
    Write-Host "        Ensure the full absolute path is correct and the file is accessible." -ForegroundColor Yellow
    exit 1
}

$TARGET_API_URL = if ($env:TARGET_API_URL) { $env:TARGET_API_URL } else { "https://api.github.com" }
Write-VerboseLog "Using TARGET_API_URL=$TARGET_API_URL"

#endregion

#region ── GitHub CLI validation ─────────────────────────────────────────────

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] GitHub CLI not authenticated." -ForegroundColor Red
    Write-Host "        Run: gh auth login  or set the GH_TOKEN environment variable." -ForegroundColor Yellow
    exit 1
}

#endregion

#region ── Storage backend ───────────────────────────────────────────────────

function Get-StorageArgs {
    $hasAws   = $env:AWS_ACCESS_KEY_ID -or $env:AWS_SECRET_ACCESS_KEY -or
                $env:AWS_BUCKET_NAME   -or $env:AWS_S3_BUCKET -or
                $env:AWS_BUCKET        -or $env:AWS_REGION -or $env:AWS_DEFAULT_REGION
    $hasAzure = [bool]$env:AZURE_STORAGE_CONNECTION_STRING

    if ($hasAws -and $hasAzure) {
        Write-Host "[ERROR] Both AWS and Azure storage variables are set. Configure only one storage backend." -ForegroundColor Red
        return $null
    }

    if ($hasAws) {
        $bucket = if ($env:AWS_BUCKET_NAME) { $env:AWS_BUCKET_NAME }
                  elseif ($env:AWS_S3_BUCKET) { $env:AWS_S3_BUCKET }
                  else { $env:AWS_BUCKET }
        $region = if ($env:AWS_REGION) { $env:AWS_REGION } else { $env:AWS_DEFAULT_REGION }

        if (-not $env:AWS_ACCESS_KEY_ID -or -not $env:AWS_SECRET_ACCESS_KEY -or -not $bucket -or -not $region) {
            Write-Host "[ERROR] AWS storage requires: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_BUCKET_NAME, AWS_REGION." -ForegroundColor Red
            return $null
        }

        Write-VerboseLog "Storage backend: AWS S3 (bucket=$bucket, region=$region)"
        return @('--aws-bucket-name', $bucket, '--aws-region', $region)
    }

    if ($hasAzure) {
        Write-VerboseLog "Storage backend: Azure Blob"
        return , @()
    }

    Write-VerboseLog "Storage backend: GitHub-owned storage"
    return @('--use-github-storage')
}

$STORAGE_ARGS = Get-StorageArgs
if ($null -eq $STORAGE_ARGS) { exit 1 }

#endregion

#region ── Functions ──────────────────────────────────────────────────────────

function Write-MigrationCsvHeader {
    param([string]$Path)
    "project-key,project-name,repo,github_org,github_repo,gh_repo_visibility,Migration_Status,Log_File" |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-MigrationCsvRow {
    param(
        [string]$Path,
        [string]$ProjectKey, [string]$ProjectName, [string]$Repo,
        [string]$GithubOrg,  [string]$GithubRepo,  [string]$Visibility,
        [string]$Status,     [string]$LogFile
    )
    ('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}"' -f
        $ProjectKey, $ProjectName, $Repo, $GithubOrg, $GithubRepo, $Visibility, $Status, $LogFile) |
        Add-Content -LiteralPath $Path -Encoding UTF8
}

function Update-MigrationCsvStatus {
    param(
        [string]$Path,
        [string]$TargetOrg,  [string]$TargetRepo,
        [string]$NewStatus,  [string]$LogFile
    )
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0) { return }

    $updated = New-Object System.Collections.Generic.List[string]
    $updated.Add($lines[0])

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $fields = $line -replace '^"|"$', '' -split '","'

        if ($fields[3] -eq $TargetOrg -and $fields[4] -eq $TargetRepo) {
            $updated.Add(('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}"' -f
                $fields[0], $fields[1], $fields[2], $fields[3], $fields[4], $fields[5], $NewStatus, $LogFile))
        }
        else {
            $updated.Add($line)
        }
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    $updated | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $Path
}

function Read-FileDelta {
    param([string]$Path, [long]$LastLen)
    if (-not (Test-Path -LiteralPath $Path)) { return @('', $LastLen) }
    $fileLen = [long](Get-Item -LiteralPath $Path).Length
    if ($fileLen -le $LastLen) { return @('', $fileLen) }

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fs.Seek($LastLen, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buf  = New-Object byte[] ($fileLen - $LastLen)
        $read = $fs.Read($buf, 0, $buf.Length)
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read) -replace "`r", ""
        return @($text, $fileLen)
    }
    finally {
        $fs.Close()
    }
}

$script:STATUS_LINE_WIDTH = 0

function Show-StatusBar {
    param([int]$QueueCount, [int]$InProgressCount, [int]$MigratedCount, [int]$FailedCount)
    $status = "QUEUE: $QueueCount / IN PROGRESS: $InProgressCount / MIGRATED: $MigratedCount / FAILED: $FailedCount"
    if ($status.Length -gt $script:STATUS_LINE_WIDTH) { $script:STATUS_LINE_WIDTH = $status.Length }
    Write-Host -NoNewline "`r$($status.PadRight($script:STATUS_LINE_WIDTH))" -ForegroundColor Cyan
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutputCsv  = if ($OutputPath) { $OutputPath } else { Join-Path $SCRIPT_DIR "repo_migration_output-$timestamp.csv" }

$queue    = New-Object System.Collections.Generic.List[object]
$migrated = New-Object System.Collections.Generic.List[string]
$failed   = New-Object System.Collections.Generic.List[string]
$skipped  = 0

foreach ($entry in $repoList) {
    $projectKey  = $entry.'project-key'
    $projectName = $entry.'project-name'
    $repo        = $entry.repo
    $githubOrg   = $entry.github_org
    $githubRepo  = $entry.github_repo
    $visibility  = $entry.gh_repo_visibility

    if (-not $projectKey -or -not $repo -or -not $githubOrg -or -not $githubRepo -or -not $visibility) {
        Write-Host "[WARNING] Skipping row with missing required fields: $projectKey/$repo" -ForegroundColor Yellow
        Write-Host "          Ensure project-key, repo, github_org, github_repo, gh_repo_visibility are populated." -ForegroundColor Yellow
        $skipped++
        continue
    }

    $queue.Add([PSCustomObject]@{
        ProjectKey  = $projectKey
        ProjectName = $projectName
        Repo        = $repo
        GithubOrg   = $githubOrg
        GithubRepo  = $githubRepo
        Visibility  = $visibility
    })
}

Write-MigrationCsvHeader -Path $OutputCsv
foreach ($item in $queue) {
    Add-MigrationCsvRow -Path $OutputCsv `
        -ProjectKey $item.ProjectKey -ProjectName $item.ProjectName -Repo $item.Repo `
        -GithubOrg  $item.GithubOrg  -GithubRepo  $item.GithubRepo -Visibility $item.Visibility `
        -Status "Pending" -LogFile ""
}

Write-Host "`n Bitbucket Server to GitHub Migration"
Write-Host "======================================"
Write-Host "`nReading input from file : '$CsvPath'"
Write-Host "Repos loaded            : $($queue.Count)"
Write-Host "Max concurrent jobs     : $MaxConcurrent"
Write-Host "Output CSV              : $OutputCsv"
Write-Host "`nStarting migration...`n"

$activeJobs = @{}
$jobLogs    = @{}
$jobLastLen = @{}

$migrationJobScript = @'
    param(
        [string]$ProjectKey,   [string]$ProjectName, [string]$Repo,
        [string]$GithubOrg,   [string]$GithubRepo,  [string]$Visibility,
        [string]$LogFile,     [string]$BbsBaseUrl,
        [string]$SshUser,     [string]$SshKeyPath,  [string]$SshKeyContent,
        [string]$TargetApiUrl,[string[]]$StorageArgs,
        [string]$BbsUsername, [string]$BbsPassword
    )

    # [START] is always the first log entry regardless of outcome
    Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [START] Migration: $ProjectKey/$Repo -> $GithubOrg/$GithubRepo (visibility: $Visibility)"

    try {
        # ── Resolve SSH key path ──────────────────────────────────────────────
        $resolvedKey = $null
        if ($SshKeyContent -and $SshKeyContent.Contains('BEGIN') -and $SshKeyContent.Contains('PRIVATE KEY')) {
            $resolvedKey = Join-Path ([System.IO.Path]::GetTempPath()) ("bbs2gh_sshkey_$(Get-Date -Format 'yyyyMMdd-HHmmssfff').pem")
            Set-Content -LiteralPath $resolvedKey -Value $SshKeyContent -NoNewline
        } elseif ($SshKeyPath) {
            $resolvedKey = $SshKeyPath
        }

        # ── Validate key ─────────────────────────────────────────────────────
        if (-not $resolvedKey -or -not (Test-Path -LiteralPath $resolvedKey)) {
            $keyDisplay = if ($resolvedKey) { $resolvedKey } else { '<empty>' }
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [ERROR] SSH private key path is invalid or missing: $keyDisplay"
            "FAILED" | Set-Content -LiteralPath "$LogFile.result"
            return
        }

        $keyEncrypted = $false
        $keyTxt = Get-Content -LiteralPath $resolvedKey -Raw -ErrorAction SilentlyContinue
        if ($keyTxt -match 'ENCRYPTED') { $keyEncrypted = $true }
        if ($keyTxt -match 'BEGIN OPENSSH PRIVATE KEY' -and $keyTxt -match 'bcrypt') { $keyEncrypted = $true }

        if ($keyEncrypted) {
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [ERROR] SSH private key is passphrase-protected. Use an unencrypted key or preload ssh-agent."
            "FAILED" | Set-Content -LiteralPath "$LogFile.result"
            return
        }

        # ── Run migration ─────────────────────────────────────────────────────
        $env:BBS_USERNAME = $BbsUsername
        $env:BBS_PASSWORD = $BbsPassword

        $storagePrintable = $StorageArgs -join ' '
        Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [DEBUG] gh bbs2gh migrate-repo --bbs-server-url $BbsBaseUrl --bbs-project $ProjectKey --bbs-repo $Repo --github-org $GithubOrg --github-repo $GithubRepo $storagePrintable --ssh-user $SshUser --ssh-private-key $resolvedKey --target-api-url $TargetApiUrl --target-repo-visibility $Visibility"

        $cmdArgs = @(
            'bbs2gh', 'migrate-repo',
            '--bbs-server-url',         $BbsBaseUrl,
            '--bbs-project',            $ProjectKey,
            '--bbs-repo',               $Repo,
            '--github-org',             $GithubOrg,
            '--github-repo',            $GithubRepo
        ) + $StorageArgs + @(
            '--ssh-user',               $SshUser,
            '--ssh-private-key',        $resolvedKey,
            '--target-api-url',         $TargetApiUrl,
            '--target-repo-visibility', $Visibility
        )

        & gh @cmdArgs 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding UTF8

        $logText = Get-Content -LiteralPath $LogFile -Raw -ErrorAction SilentlyContinue

        if ($logText -match 'No operation will be performed') {
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [FAILED] No operation performed - repository may already exist or migration was skipped."
            "FAILED" | Set-Content -LiteralPath "$LogFile.result"
            return
        }

        if ($logText -notmatch 'State: SUCCEEDED') {
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [FAILED] Migration did not reach SUCCEEDED state."
            "FAILED" | Set-Content -LiteralPath "$LogFile.result"
            return
        }

        Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [SUCCESS] Migration: $ProjectKey/$Repo -> $GithubOrg/$GithubRepo"
        "SUCCESS" | Set-Content -LiteralPath "$LogFile.result"
    }
    catch {
        Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [ERROR] $($_.Exception.Message)"
        "FAILED" | Set-Content -LiteralPath "$LogFile.result"
    }
'@
$migrationJobBlock = [scriptblock]::Create($migrationJobScript)

while ($queue.Count -gt 0 -or $activeJobs.Count -gt 0) {

    # ── Start new jobs up to MaxConcurrent ───────────────────────────────────
    while ($activeJobs.Count -lt $MaxConcurrent -and $queue.Count -gt 0) {
        $item = $queue[0]
        $queue.RemoveAt(0)

        $logFile = Join-Path $SCRIPT_DIR "migration-$($item.GithubRepo)-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

        Update-MigrationCsvStatus -Path $OutputCsv `
            -TargetOrg $item.GithubOrg -TargetRepo $item.GithubRepo `
            -NewStatus "In Progress" -LogFile $logFile

        $job = Start-Job -ScriptBlock $migrationJobBlock -ArgumentList `
            $item.ProjectKey, $item.ProjectName, $item.Repo,
            $item.GithubOrg,  $item.GithubRepo,  $item.Visibility,
            $logFile, $BBS_BASE_URL,
            $env:SSH_USER, $env:SSH_PRIVATE_KEY_PATH, $env:SSH_PRIVATE_KEY,
            $TARGET_API_URL, $STORAGE_ARGS,
            $env:BBS_USERNAME, $env:BBS_PASSWORD

        $activeJobs[$job.Id] = $item
        $jobLogs[$job.Id]    = $logFile
        $jobLastLen[$job.Id] = [long]0

        Show-StatusBar -QueueCount $queue.Count -InProgressCount $activeJobs.Count `
            -MigratedCount $migrated.Count -FailedCount $failed.Count
    }

    # ── Stream new log content from active jobs ───────────────────────────────
    foreach ($jid in @($activeJobs.Keys)) {
        $log  = $jobLogs[$jid]
        $last = [long]$jobLastLen[$jid]
        if (Test-Path -LiteralPath $log) {
            $delta, $newLen = Read-FileDelta -Path $log -LastLen $last
            if (-not [string]::IsNullOrEmpty($delta)) {
                Write-Host ""
                foreach ($line in ($delta -split "`n")) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host "  $line" }
                }
                $jobLastLen[$jid] = $newLen
                Show-StatusBar -QueueCount $queue.Count -InProgressCount $activeJobs.Count `
                    -MigratedCount $migrated.Count -FailedCount $failed.Count
            }
            else {
                $jobLastLen[$jid] = $newLen
            }
        }
    }

    # ── Collect completed jobs ────────────────────────────────────────────────
    foreach ($jid in @($activeJobs.Keys)) {
        $job = Get-Job -Id $jid -ErrorAction SilentlyContinue
        if ($null -eq $job -or $job.State -eq 'Running') { continue }

        $item    = $activeJobs[$jid]
        $logFile = $jobLogs[$jid]
        $result  = 'FAILED'

        if (Test-Path -LiteralPath "$logFile.result") {
            $result = (Get-Content -LiteralPath "$logFile.result" -TotalCount 1).Trim()
            Remove-Item -Force -LiteralPath "$logFile.result" -ErrorAction SilentlyContinue
        }

        if ($result -eq 'SUCCESS') {
            $migrated.Add("$($item.ProjectKey)/$($item.Repo) -> $($item.GithubOrg)/$($item.GithubRepo)")
            Update-MigrationCsvStatus -Path $OutputCsv `
                -TargetOrg $item.GithubOrg -TargetRepo $item.GithubRepo `
                -NewStatus "Success" -LogFile $logFile
            Write-Host "`n[OK]     $($item.ProjectKey)/$($item.Repo) -> $($item.GithubOrg)/$($item.GithubRepo)" -ForegroundColor Green
        }
        else {
            $failed.Add("$($item.ProjectKey)/$($item.Repo) -> $($item.GithubOrg)/$($item.GithubRepo)")
            Update-MigrationCsvStatus -Path $OutputCsv `
                -TargetOrg $item.GithubOrg -TargetRepo $item.GithubRepo `
                -NewStatus "Failure" -LogFile $logFile
            Write-Host "`n[FAILED] $($item.ProjectKey)/$($item.Repo) -> $($item.GithubOrg)/$($item.GithubRepo)" -ForegroundColor Red
        }

        $activeJobs.Remove($jid)
        $jobLogs.Remove($jid)
        $jobLastLen.Remove($jid)
        try { Remove-Job -Id $jid -Force -ErrorAction SilentlyContinue } catch { }

        Show-StatusBar -QueueCount $queue.Count -InProgressCount $activeJobs.Count `
            -MigratedCount $migrated.Count -FailedCount $failed.Count
    }

    Start-Sleep -Seconds 2
}

#endregion

#region ── Summary ────────────────────────────────────────────────────────────

$totalRepos = $repoList.Count - $skipped

if ($failed.Count -gt 0) {
    $finalMessage = "Some migrations failed. Review the log files and output CSV before retrying."
    $finalColor   = "Red"
}
elseif ($migrated.Count -eq $totalRepos) {
    $finalMessage = "All repositories migrated successfully."
    $finalColor   = "Green"
}
else {
    $finalMessage = "Migration completed with partial results. Review the output CSV."
    $finalColor   = "Yellow"
}

Write-Host "`nMigration Summary"
Write-Host "================="
Write-Host "[SUMMARY] Total repos : $totalRepos"
Write-Host "[SUMMARY] Migrated    : $($migrated.Count)"
Write-Host "[SUMMARY] Failed      : $($failed.Count)"
Write-Host "[SUMMARY] Output CSV  : $OutputCsv"
Write-Host "`n$finalMessage`n" -ForegroundColor $finalColor

#endregion