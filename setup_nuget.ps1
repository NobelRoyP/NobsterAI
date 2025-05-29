# PowerShell script to download NuGet.exe and add its directory to the user PATH environment variable

$nugetUrl = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
$nugetDir = "$env:USERPROFILE\\nuget"
$nugetExePath = "$nugetDir\\nuget.exe"

# Create directory if it doesn't exist
if (-Not (Test-Path -Path $nugetDir)) {
    New-Item -ItemType Directory -Path $nugetDir | Out-Null
}

# Download nuget.exe
Invoke-WebRequest -Uri $nugetUrl -OutFile $nugetExePath

# Check if nuget.exe was downloaded
if (Test-Path -Path $nugetExePath) {
    Write-Host "NuGet.exe downloaded successfully to $nugetExePath"
} else {
    Write-Error "Failed to download NuGet.exe"
    exit 1
}

# Add nuget directory to user PATH if not already present
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$nugetDir*") {
    $newPath = "$currentPath;$nugetDir"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Host "Added $nugetDir to user PATH environment variable."
    Write-Host "Please restart your terminal or IDE to apply the changes."
} else {
    Write-Host "$nugetDir is already in the user PATH."
}
