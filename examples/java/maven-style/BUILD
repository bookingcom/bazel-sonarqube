load("@bazel_sonarqube//:defs.bzl", "sonarqube_maven_style")

java_library(
    name = "app",
    srcs = [
        "src/main/java/com/maven/MavenApp.java"
    ]
)


java_test(
    name = "MavenAppTest",
    srcs = ["src/test/java/com/maven/MavenAppTest.java"],
    deps = [
        ":app",
        "@maven//:junit_junit",
    ],
    size = "small",
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
    scm_dir = "../../.git",
    scm_prefix = "examples/java",
    extra_arguments = {
        "sonar.organization": "bookingcom-1"
    }
)
