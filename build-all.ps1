#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$VERSION    = "1.5.0-SNAPSHOT"
$VCS_REF    = (git rev-parse --short HEAD).Trim()
$BUILD_DATE = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$REGISTRY   = "your-registry.example.com/pinot"
$ROLES      = @("controller", "broker", "server", "minion")

function Assert-LastExit($msg) {
  if ($LASTEXITCODE -ne 0) {
    throw "[FAIL] $msg (exit=$LASTEXITCODE)"
  }
}

# --- 1. Проверяем, что Wolfi-base доступен -----------------------------
Write-Host "=== Verifying base images ===" -ForegroundColor Cyan
@(
  "cgr.dev/chainguard/wolfi-base:latest"
) | ForEach-Object {
  Write-Host -NoNewline "  $_ ... "
  docker manifest inspect $_ > $null 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "NOT FOUND" -ForegroundColor Red
    throw "Base image $_ is not accessible. Check Dockerfile.base FROM line."
  }
  Write-Host "OK" -ForegroundColor Green
}

# --- 2. Сборка base ----------------------------------------------------
Write-Host "=== Building base image ===" -ForegroundColor Cyan
docker build `
  -f docker/images/pinot/Dockerfile.base `
  --target build `
  --build-arg PINOT_VERSION=$VERSION `
  --build-arg JDK_VERSION=21 `
  -t "pinot-builder:$VERSION" `
  .
if ($LASTEXITCODE -ne 0) { throw "[FAIL] build builder stage" }

# Шаг 2: финальная стадия (использует кеш build-стадии)
docker build `
  -f docker/images/pinot/Dockerfile.base `
  --target pinot-base `
  --build-arg PINOT_VERSION=$VERSION `
  --build-arg JDK_VERSION=21 `
  -t "pinot-base:$VERSION" `
  -t "pinot-base:latest" `
  .

Assert-LastExit "build base"

# --- 3. Сборка ролей ---------------------------------------------------
foreach ($role in $ROLES) {
  Write-Host "=== Building pinot-$role ===" -ForegroundColor Cyan
  $tag1 = "${REGISTRY}/pinot-${role}:${VERSION}"
  $tag2 = "${REGISTRY}/pinot-${role}:${VERSION}-${VCS_REF}"
  $tag3 = "${REGISTRY}/pinot-${role}:latest"

  docker build `
    -f "docker/images/pinot/Dockerfile.$role" `
    --build-arg BASE_IMAGE="pinot-base:$VERSION" `
    -t $tag1 `
    -t $tag2 `
    -t $tag3 `
    .
  Assert-LastExit "build pinot-$role"
}

# --- 4. Сканирование Trivy (опционально) -------------------------------
$trivy = Get-Command trivy -ErrorAction SilentlyContinue
if ($null -eq $trivy) {
  Write-Host "trivy not found in PATH, skipping vulnerability scan." -ForegroundColor Yellow
} else {
  Write-Host "=== Scanning all images with Trivy ===" -ForegroundColor Cyan
  foreach ($role in $ROLES) {
    Write-Host "--- $role ---"
    $tag = "${REGISTRY}/pinot-${role}:${VERSION}"
    trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed $tag `
      | Tee-Object "trivy-$role.txt"
  }
}

Write-Host "=== Done ===" -ForegroundColor Green
