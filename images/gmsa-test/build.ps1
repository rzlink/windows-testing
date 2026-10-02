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
    [Parameter(Mandatory = $true)]
    [ValidateSet("1809", "ltsc2022", "ltsc2025")]
    [string]$OSVersion,

    [string]$BaseImage,

    [string]$Registry = "gcr.io/k8s-staging-e2e-test-images",

    [string]$ImageName = "gmsa-test",

    [string]$Version,

    [switch]$Push
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$expectedOSBuilds = @{
    "1809" = "10.0.17763"
    "ltsc2022" = "10.0.20348"
    "ltsc2025" = "10.0.26100"
}
$expectedOSBuild = $expectedOSBuilds[$OSVersion]

function Get-ImageRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $digestSeparator = $Reference.IndexOf("@")
    if ($digestSeparator -ge 0) {
        return $Reference.Substring(0, $digestSeparator)
    }

    $lastSlash = $Reference.LastIndexOf("/")
    $tagSeparator = $Reference.LastIndexOf(":")
    if ($tagSeparator -gt $lastSlash) {
        return $Reference.Substring(0, $tagSeparator)
    }

    return $Reference
}

function Resolve-BaseImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference,

        [Parameter(Mandatory = $true)]
        [string]$WindowsBuild
    )

    $manifestJSON = & docker manifest inspect $Reference
    if ($LASTEXITCODE -ne 0) {
        throw "Inspecting base image $Reference failed with exit code $LASTEXITCODE."
    }

    try {
        $manifest = ($manifestJSON -join [Environment]::NewLine) | ConvertFrom-Json
    } catch {
        throw "Docker returned invalid manifest JSON for ${Reference}: $($_.Exception.Message)"
    }

    if (-not ($manifest.PSObject.Properties.Name -contains "manifests")) {
        return $Reference
    }

    $matchingManifests = @(
        $manifest.manifests | Where-Object {
            $platform = $_.platform
            if ($platform.os -ne "windows" -or $platform.architecture -ne "amd64") {
                $false
            } else {
                $osVersionProperty = $platform.PSObject.Properties["os.version"]
                if ($null -eq $osVersionProperty) {
                    $false
                } else {
                    $osVersion = $osVersionProperty.Value
                    $osVersion -eq $WindowsBuild -or $osVersion.StartsWith("$WindowsBuild.")
                }
            }
        }
    )
    if ($matchingManifests.Count -ne 1) {
        throw "Expected one windows/amd64 child for Windows build $WindowsBuild in $Reference; " +
            "found $($matchingManifests.Count)."
    }

    $repository = Get-ImageRepository -Reference $Reference
    return "$repository@$($matchingManifests[0].digest)"
}

if (-not $Version) {
    $Version = (Get-Content -Path (Join-Path $PSScriptRoot "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Image version must not be empty."
}

if ([string]::IsNullOrWhiteSpace($BaseImage)) {
    $BaseImage = "registry.k8s.io/e2e-test-images/busybox:1.38.0-1"
}
$resolvedBaseImage = Resolve-BaseImage -Reference $BaseImage -WindowsBuild $expectedOSBuild

$image = "{0}/{1}:{2}-windows-amd64-{3}" -f $Registry.TrimEnd("/"), $ImageName, $Version, $OSVersion
$arguments = @(
    "build",
    "--pull",
    "--build-arg", "BASE_IMAGE=$resolvedBaseImage",
    "--build-arg", "OS_VERSION=$OSVersion",
    "--tag", $image,
    $PSScriptRoot
)

& docker @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Building $image failed with exit code $LASTEXITCODE."
}

$metadata = & docker image inspect --format "{{.Os}}|{{.Architecture}}|{{.OsVersion}}" $image
if ($LASTEXITCODE -ne 0) {
    throw "Inspecting $image failed with exit code $LASTEXITCODE."
}

$metadataParts = $metadata.Trim().Split("|")
if ($metadataParts.Count -ne 3) {
    throw "Docker returned unexpected platform metadata for ${image}: '$metadata'."
}

$actualOSBuild = $metadataParts[2]
if ($metadataParts[0] -ne "windows" -or $metadataParts[1] -ne "amd64" -or
    -not ($actualOSBuild -eq $expectedOSBuild -or $actualOSBuild.StartsWith("$expectedOSBuild."))) {
    throw "Image $image has platform '$($metadataParts[0])/$($metadataParts[1])' and OS version " +
        "'$actualOSBuild'; expected 'windows/amd64' and Windows build '$expectedOSBuild' for $OSVersion."
}

if ($Push) {
    & docker push $image
    if ($LASTEXITCODE -ne 0) {
        throw "Pushing $image failed with exit code $LASTEXITCODE."
    }
}

Write-Output "Built $image from $resolvedBaseImage"
Write-Output $image
