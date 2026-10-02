# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

[CmdletBinding()]
param(
    [string]$Registry = "gcr.io/k8s-staging-e2e-test-images",

    [string]$ImageName = "gmsa-test",

    [string]$Version,

    [switch]$Push
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $Version) {
    $Version = (Get-Content -Path (Join-Path $PSScriptRoot "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Image version must not be empty."
}

$windowsBuilds = [ordered]@{
    "1809" = "10.0.17763"
    "ltsc2022" = "10.0.20348"
    "ltsc2025" = "10.0.26100"
}
$repository = "{0}/{1}" -f $Registry.TrimEnd("/"), $ImageName
$target = "${repository}:$Version"
$sources = @()
$sourceDescriptors = @{}

foreach ($entry in $windowsBuilds.GetEnumerator()) {
    $source = "${repository}:$Version-windows-amd64-$($entry.Key)"
    $manifestJSON = & docker manifest inspect --verbose $source
    if ($LASTEXITCODE -ne 0) {
        throw "Inspecting source image $source failed with exit code $LASTEXITCODE."
    }

    try {
        $manifest = ($manifestJSON -join [Environment]::NewLine) | ConvertFrom-Json
    } catch {
        throw "Docker returned invalid manifest JSON for ${source}: $($_.Exception.Message)"
    }

    $descriptor = $manifest.Descriptor
    $platform = $descriptor.platform
    $osVersion = $platform."os.version"
    if ($platform.os -ne "windows" -or $platform.architecture -ne "amd64" -or
        -not ($osVersion -eq $entry.Value -or $osVersion.StartsWith("$($entry.Value)."))) {
        throw "Source $source has platform '$($platform.os)/$($platform.architecture)' and OS version " +
            "'$osVersion'; expected 'windows/amd64' and Windows build '$($entry.Value)'."
    }

    $sources += $source
    $sourceDescriptors[$entry.Key] = @{
        Digest = $descriptor.digest
        OSVersion = $osVersion
    }
}

& docker manifest rm $target 2>$null | Out-Null
& docker manifest create $target @sources
if ($LASTEXITCODE -ne 0) {
    throw "Creating manifest $target failed with exit code $LASTEXITCODE."
}

foreach ($entry in $windowsBuilds.GetEnumerator()) {
    $source = "${repository}:$Version-windows-amd64-$($entry.Key)"
    $osVersion = $sourceDescriptors[$entry.Key].OSVersion
    & docker manifest annotate --os windows --arch amd64 --os-version $osVersion $target $source
    if ($LASTEXITCODE -ne 0) {
        throw "Annotating $source in $target failed with exit code $LASTEXITCODE."
    }
}

if (-not $Push) {
    Write-Output "Created local manifest $target. Re-run with -Push to publish and verify it."
    return
}

& docker manifest push --purge $target
if ($LASTEXITCODE -ne 0) {
    throw "Pushing manifest $target failed with exit code $LASTEXITCODE."
}

$publishedJSON = & docker manifest inspect $target
if ($LASTEXITCODE -ne 0) {
    throw "Inspecting published manifest $target failed with exit code $LASTEXITCODE."
}
$published = ($publishedJSON -join [Environment]::NewLine) | ConvertFrom-Json
$publishedWindows = @(
    $published.manifests | Where-Object {
        $_.platform.os -eq "windows" -and $_.platform.architecture -eq "amd64"
    }
)
if ($publishedWindows.Count -ne $windowsBuilds.Count) {
    throw "Published manifest $target contains $($publishedWindows.Count) Windows variants; " +
        "expected $($windowsBuilds.Count)."
}

foreach ($entry in $windowsBuilds.GetEnumerator()) {
    $expectedDescriptor = $sourceDescriptors[$entry.Key]
    $matches = @(
        $publishedWindows | Where-Object {
            $_.digest -eq $expectedDescriptor.Digest -and
                $_.platform."os.version" -eq $expectedDescriptor.OSVersion
        }
    )
    if ($matches.Count -ne 1) {
        throw "Published manifest $target does not contain the verified $($entry.Key) descriptor."
    }
}

Write-Output "Published and verified $target"
