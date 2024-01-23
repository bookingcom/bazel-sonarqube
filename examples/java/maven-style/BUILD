load("@bazel_sonarqube//:defs.bzl", "sonarqube_maven_style")

java_library(
    name = "app",
    srcs = [
        "src/main/java/com/maven/MavenApp.java"
    ],
    deps = [
        "@maven//:ch_qos_logback_logback_core",
        "@maven//:org_slf4j_slf4j_api",
    ],
)


java_test(
    name = "MavenAppTest",
    srcs = ["src/test/java/com/maven/MavenAppTest.java"],
    deps = [
        ":app",
        "@maven//:junit_junit",
    ],
    size = "small",
    test_class = "com.maven.MavenAppTest",
)

sonarqube_maven_style(
    name = "sonarqube",
    targets = [
        ":app"
    ],
    test_reports = [ "//:test_reports" ],
    test_targets = [
        ":MavenAppTest",
    ],
    coverage_report = "//:coverage_report",
    project_key = "com.example.bazel-sonarqube:maven-style",
    project_name = "My Project with Maven Style sonarqube rule",
    tags = ["manual"],
    testonly = True,
    sq_properties = "sonar-project.properties",
    extra_arguments = {
        "sonar.organization": "bookingcom-1"
    }
)
