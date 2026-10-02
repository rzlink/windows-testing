# GMSA test image

This image extends the Kubernetes Windows busybox test image with the Windows
components required by the upstream GMSA end-to-end tests.

Nano Server LTSC 2025 does not include the SMB redirector used by
`LanmanWorkstation`. Without it, a container cannot establish the Netlogon
secure channel required to authenticate a group Managed Service Account. The
LTSC 2025 image therefore installs the
`Microsoft.NanoServer.RemoteFS.Client` capability during the image build.

The 1809 and LTSC 2022 variants remain unchanged derivatives of the matching
busybox image so that one multi-platform image can be used by the GMSA tests.

## Build

The Dockerfile executes Windows commands and must be built by a compatible
Windows builder. A Linux-hosted Docker buildx builder can assemble Windows
layers but cannot execute the `RUN` instructions in this image.

Run `build.ps1` once on a compatible builder for each supported Windows
version. The script resolves the matching child digest from the busybox image
index rather than letting Docker select a manifest according to the builder
host:

```powershell
./build.ps1 -OSVersion 1809
./build.ps1 -OSVersion ltsc2022
./build.ps1 -OSVersion ltsc2025
```

Use `-BaseImage` when testing a different busybox version or an immutable
busybox digest. A multi-platform override is resolved by Windows build number;
a single-platform tag or digest is accepted directly and checked after the
build. Use `-Registry`, `-ImageName`, and `-Version` to override the output
reference.

After the build, the script verifies that the image is `windows/amd64` and
that its Windows build number matches `-OSVersion`. `-Push` is allowed only
after that check succeeds.

The default base image is:

```text
registry.k8s.io/e2e-test-images/busybox:1.38.0-1
```

Its per-OS images are referenced by immutable child digest because the
production registry does not publish the staging architecture tags.

The default output tags are:

```text
gcr.io/k8s-staging-e2e-test-images/gmsa-test:1.0.0-windows-amd64-1809
gcr.io/k8s-staging-e2e-test-images/gmsa-test:1.0.0-windows-amd64-ltsc2022
gcr.io/k8s-staging-e2e-test-images/gmsa-test:1.0.0-windows-amd64-ltsc2025
```

After all three OS-specific images have been pushed, create and publish the
staging manifest:

```powershell
./publish-manifest.ps1 -Push
```

The script verifies each source image's platform and exact Windows version,
pins every source by digest before assembling the manifest, pushes it as
`gmsa-test:1.0.0`, and verifies the published descriptors. Promotion
configuration must be added separately before that staging manifest can be
promoted to
`registry.k8s.io/e2e-test-images/gmsa-test:1.0.0`.

## Servicing behavior

`install-remotefs.cmd` runs only for LTSC 2025. DISM exit code `3010` means
that capability installation succeeded and a restart is required. Windows
containers cannot restart while an image is being built, so installation and
verification deliberately occur in separate Docker layers.

The build fails unless the subsequent layer can find `MRxSmb20` and confirms
that `LanmanWorkstation` is configured for automatic startup.

## Validation

Before promotion:

1. Run the three upstream GMSA end-to-end tests against the LTSC 2025 image.
2. Run the GMSA tests against the LTSC 2022 image to detect regressions.
3. Test the 1809 variant while Windows Server 2019 remains supported.
4. Record and promote the exact manifest digest used by the test clusters.
