load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def _bazel_version_impl(ctx):
    ctx.file("WORKSPACE", "workspace(name = \"{name}\")\n".format(name = ctx.name), executable = False)
    ctx.file("BUILD.bazel", "", executable = False)
    ctx.file("defs.bzl", "VERSION='%s'" % native.bazel_version, executable = False)

_bazel_version = repository_rule(implementation = _bazel_version_impl)

def bazel_sonarqube_repositories(
        sonar_scanner_cli_version = "3.3.0.1492",
        sonar_scanner_cli_sha256 = "0fabd3fa2e10bbfc5cdf64765ff35e88e7937e48aad51d84401b9f36dbde3678",
        bazel_skylib_version = "1.0.3",
        bazel_skylib_sha256 = "1c531376ac7e5a180e0237938a2536de0c54d93f5c278634818e0efc952dd56c"):
    maybe(
        http_archive,
        name = "org_sonarsource_scanner_cli_sonar_scanner_cli",
        build_file = "@bazel_sonarqube//:BUILD.sonar_scanner",
        sha256 = sonar_scanner_cli_sha256,
        strip_prefix = "sonar-scanner-" + sonar_scanner_cli_version,
        urls = [
            "https://repo1.maven.org/maven2/org/sonarsource/scanner/cli/sonar-scanner-cli/%s/sonar-scanner-cli-%s.zip" % (sonar_scanner_cli_version, sonar_scanner_cli_version),
            "https://jcenter.bintray.com/org/sonarsource/scanner/cli/sonar-scanner-cli/%s/sonar-scanner-cli-%s.zip" % (sonar_scanner_cli_version, sonar_scanner_cli_version),
        ],
    )

    maybe(
        http_archive,
        name = "bazel_skylib",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/%s/bazel-skylib-%s.tar.gz" % (bazel_skylib_version, bazel_skylib_version),
            "https://github.com/bazelbuild/bazel-skylib/releases/download/%s/bazel-skylib-%s.tar.gz" % (bazel_skylib_version, bazel_skylib_version),
        ],
        sha256 = bazel_skylib_sha256,
    )

    maybe(
        _bazel_version,
        name = "bazel-version",
    )
