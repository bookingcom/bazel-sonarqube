workspace(name = "bazel_sonarqube")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//:repositories.bzl", "bazel_sonarqube_repositories")

bazel_sonarqube_repositories()

http_archive(
    name = "io_bazel_stardoc",
    sha256 = "6d07d18c15abb0f6d393adbd6075cd661a2219faab56a9517741f0fc755f6f3c",
    strip_prefix = "stardoc-0.4.0",
    urls = ["https://github.com/bazelbuild/stardoc/archive/0.4.0.tar.gz"],
)

load("@io_bazel_stardoc//:setup.bzl", "stardoc_repositories")

stardoc_repositories()

RULES_JVM_EXTERNAL_TAG = "4.0"

RULES_JVM_EXTERNAL_SHA = "31701ad93dbfe544d597dbe62c9a1fdd76d81d8a9150c2bf1ecf928ecdf97169"

http_archive(
    name = "rules_jvm_external",
    sha256 = RULES_JVM_EXTERNAL_SHA,
    strip_prefix = "rules_jvm_external-%s" % RULES_JVM_EXTERNAL_TAG,
    url = "https://github.com/bazelbuild/rules_jvm_external/archive/%s.zip" % RULES_JVM_EXTERNAL_TAG,
)

load("@rules_jvm_external//:defs.bzl", "maven_install")
load("@rules_jvm_external//:specs.bzl", "maven")

maven_install(
    artifacts = [
        maven.artifact("junit", "junit", "4.12", testonly=True),
        maven.artifact("ch.qos.logback", "logback-core", "1.4.14"),
        maven.artifact("org.slf4j", "slf4j-api", "2.0.11"),
    ],
    repositories = [
        "https://jcenter.bintray.com/",
        "https://repo1.maven.org/maven2",
    ],
)
