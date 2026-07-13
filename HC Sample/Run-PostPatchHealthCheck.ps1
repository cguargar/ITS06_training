<#
===============================================================================
 Run-PostPatchHealthCheck.ps1
 Purpose : Runs PostPatch-HealthCheck.sql against a list of SQL Server
           instances after patching, and produces a single colour-coded
           HTML report summarising pass/warn/fail results per server.

 Usage   : .\Run-PostPatchHealthCheck.ps1 -ServerListPath .\servers.txt
 Requires: sqlcmd (or SqlServer PowerShell module), network access to targets
===============================================================================
#>

param(
    [string]$ServerListPath = ".\servers.txt",     # one instance name per line
    [string]$SqlScriptPath  = ".\PostPatch-HealthCheck.sql",
    [string]$OutputPath     = ".\PostPatchHealthCheck_Report.html"
)

# ------------------------------------------------------------------
# 1. Load target server list
# ------------------------------------------------------------------
if (-not (Test-Path $ServerListPath)) {
    Write-Error "Server list not found at $ServerListPath. Create a text file with one instance per line."
    exit 1
}
$servers = Get-Content $ServerListPath | Where-Object { $_.Trim() -ne "" }

$reportSections = @()

# ------------------------------------------------------------------
# 2. Loop through each server and run the health check script
# ------------------------------------------------------------------
foreach ($server in $servers) {

    Write-Host "Running health check on $server ..." -ForegroundColor Cyan

    try {
        # -h -1 removes column header repetition; adjust -W for wide output
        $rawResults = sqlcmd -S $server -i $SqlScriptPath -W -s "|" -h -1 2>&1
        $status     = "Success"
    }
    catch {
        $rawResults = "ERROR connecting to $server : $_"
        $status     = "ConnectionFailed"
    }

    # Simple pass/warn/fail tally based on keywords in the output
    $failCount = ($rawResults | Select-String -Pattern "FAIL").Count
    $warnCount = ($rawResults | Select-String -Pattern "WARN").Count

    if ($status -eq "ConnectionFailed") {
        $overallStatus = "FAIL"
        $rowColor      = "#f8d7da"   # red
    }
    elseif ($failCount -gt 0) {
        $overallStatus = "FAIL"
        $rowColor      = "#f8d7da"   # red
    }
    elseif ($warnCount -gt 0) {
        $overallStatus = "WARN"
        $rowColor      = "#fff3cd"   # yellow
    }
    else {
        $overallStatus = "OK"
        $rowColor      = "#d4edda"   # green
    }

    $reportSections += [PSCustomObject]@{
        Server    = $server
        Status    = $overallStatus
        FailCount = $failCount
        WarnCount = $warnCount
        Color     = $rowColor
        Details   = ($rawResults -join "`n")
    }
}

# ------------------------------------------------------------------
# 3. Build HTML report
# ------------------------------------------------------------------
$htmlRows = ""
foreach ($section in $reportSections) {
    $safeDetails = [System.Web.HttpUtility]::HtmlEncode($section.Details) -replace "`n", "<br>"

    $htmlRows += @"
<tr style="background-color:$($section.Color);">
    <td style="padding:8px; border:1px solid #ccc;"><b>$($section.Server)</b></td>
    <td style="padding:8px; border:1px solid #ccc; text-align:center;">$($section.Status)</td>
    <td style="padding:8px; border:1px solid #ccc; text-align:center;">$($section.FailCount)</td>
    <td style="padding:8px; border:1px solid #ccc; text-align:center;">$($section.WarnCount)</td>
</tr>
<tr>
    <td colspan="4" style="padding:8px; border:1px solid #ccc; font-family:Consolas, monospace; font-size:11px; white-space:pre-wrap;">
        <details><summary>View raw output</summary>$safeDetails</details>
    </td>
</tr>
"@
}

$html = @"
<html>
<head>
    <title>Post-Patch Database Health Check Report</title>
</head>
<body style="font-family: Segoe UI, Arial, sans-serif;">
    <h2>Post-Patch Database Health Check Report</h2>
    <p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")</p>
    <table style="border-collapse: collapse; width:100%;">
        <tr style="background-color:#343a40; color:white;">
            <th style="padding:8px; border:1px solid #ccc;">Server</th>
            <th style="padding:8px; border:1px solid #ccc;">Status</th>
            <th style="padding:8px; border:1px solid #ccc;">Fail Count</th>
            <th style="padding:8px; border:1px solid #ccc;">Warn Count</th>
        </tr>
        $htmlRows
    </table>
</body>
</html>
"@

$html | Out-File -FilePath $OutputPath -Encoding utf8

Write-Host "`nReport generated: $OutputPath" -ForegroundColor Green

# ------------------------------------------------------------------
# 4. Optional: exit with non-zero code if any server failed
#    (useful for CI/CD or scheduled task alerting)
# ------------------------------------------------------------------
if ($reportSections.Status -contains "FAIL") {
    Write-Warning "One or more servers reported FAIL status after patching."
    exit 1
}
