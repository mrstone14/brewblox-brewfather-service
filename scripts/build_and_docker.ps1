<#
.SYNOPSIS
  Build the Python wheel, export requirements.txt, then build (and optionally push) a multi-platform Docker image.

.PARAMETER DockerRepo
  Docker repository (e.g. myorg/reponame). Defaults to $env:DOCKER_REPO

.PARAMETER DockerUser
  Docker username (optional). Defaults to $env:DOCKER_USER

.PARAMETER DockerPassword
  Docker password (optional). Defaults to $env:DOCKER_PASSWORD

.PARAMETER Push
  If specified, push the built image to the registry. Otherwise the image is loaded locally (requires buildx --load support).

.EXAMPLE
  .\build_and_docker.ps1 -DockerRepo "myorg/brewblox-brewfather-service" -Push
#>

param(
    [string]$DockerRepo = $env:DOCKER_REPO,
    [string]$DockerUser = $env:DOCKER_USER,
    [string]$DockerPassword = $env:DOCKER_PASSWORD,
    [switch]$Push
)

$ErrorActionPreference = 'Stop'

function Write-Log { param($m) Write-Host "[build] $m" }

Write-Log "Starting build_and_docker.ps1"

if (-not $DockerRepo) {
    Write-Log "ERROR: DockerRepo not provided. Set -DockerRepo or set environment variable DOCKER_REPO."
    exit 1
}

# Check for git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Log "ERROR: git not found in PATH."
    exit 1
}

# Determine branch/tag
try {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
} catch {
    $branch = ''
}
if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'HEAD') {
    $branch = (git rev-parse --short HEAD).Trim()
}
$tag = $branch -replace '/', '-' -replace '\\s+', '-'
$tag = $tag.ToLower()
Write-Log "Branch: $branch  Tag: $tag"

# Ensure Poetry
if (-not (Get-Command poetry -ErrorAction SilentlyContinue)) {
    Write-Log "ERROR: poetry not found. Please install Poetry: https://python-poetry.org/docs/#installation"
    exit 1
}

# Build wheel
Write-Log "Building wheel..."
poetry build -f wheel

# Export requirements.txt for Dockerfile
Write-Log "Exporting requirements.txt..."
poetry export -f requirements.txt --output requirements.txt --without-hashes

if (-not (Test-Path -Path .\dist)) {
    Write-Log "Warning: dist/ directory not found after build. poetry build should create it."
}

# Optional Docker login
if ($DockerUser -and $DockerPassword) {
    Write-Log "Logging into Docker registry as $DockerUser"
    # echo password | docker login -u user --password-stdin
    $DockerPassword | docker login -u $DockerUser --password-stdin
}

# service_info build arg
$gitDescribe = ''
try { $gitDescribe = (git describe --always).Trim() } catch { $gitDescribe = (git rev-parse --short HEAD).Trim() }
$serviceInfo = "$gitDescribe @ $(Get-Date -Format o)"
Write-Log "service_info: $serviceInfo"

# Build args
$tagFull = "$DockerRepo`:$tag"
$platforms = "linux/amd64,linux/arm/v7,linux/arm64/v8"

$buildCmd = @('buildx','build','--tag',$tagFull,'--build-arg',["service_info=$serviceInfo"],'--platform',$platforms)
if ($Push) { $buildCmd += '--push' } else { $buildCmd += '--load' }
$buildCmd += 'docker'

Write-Log "Running: docker $($buildCmd -join ' ')"

# Run docker buildx build
$proc = & docker @buildCmd
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: docker buildx build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Log "Done. Built image: $tagFull"
if ($Push) { Write-Log "Image pushed to registry." } else { Write-Log "Image loaded locally (or buildx created image)." }
