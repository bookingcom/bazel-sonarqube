"""
Rules to analyse Bazel projects with SonarQube.
"""

load("@bazel-version//:defs.bzl", _bazel_version = "VERSION")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:versions.bzl", "versions")

def sonarqube_coverage_generator_binary(name = None):
    srcs = [
        "src/main/java/com/google/devtools/coverageoutputgenerator/SonarQubeCoverageReportPrinter.java",
    ]
    if versions.is_at_least(threshold = "6.0", version = _bazel_version):
        srcs = ["src/main/java/com/google/devtools/coverageoutputgenerator/SonarQubeCoverageGenerator.java"] + srcs
    elif versions.is_at_least(threshold = "4.0", version = _bazel_version):
        srcs = ["src/bazel4/java/com/google/devtools/coverageoutputgenerator/SonarQubeCoverageGenerator.java"] + srcs
    else:
        fail("bazel %s not supported" % _bazel_version)
    native.java_binary(
        name = "SonarQubeCoverageGenerator",
        srcs = srcs,
        main_class = "com.google.devtools.coverageoutputgenerator.SonarQubeCoverageGenerator",
        deps = ["@remote_coverage_tools//:all_lcov_merger_lib"],
    )

TargetInfo = provider(
    fields = {
        "deps": "depset of targets",
    },
)

SqProjectInfo = provider(
    fields = {
        "srcs": "main sources",
        "test_srcs": "test sources",
    },
)

SourceInfo = provider(
    doc = """Provider for the SonarQube scanner to collect source files from targets.""",
    fields = {
        "source_files": "depset of source files",
    }
)

def _source_info_aspect_impl(target, ctx): # buildifier: disable=unused-variable
    """See source_info_aspect"""
    srcs = getattr(ctx.rule.attr, "srcs", [])
    source_files = depset(transitive = [t.files for t in srcs])
    return [SourceInfo(source_files = source_files)]

source_info_aspect = aspect(
    implementation = _source_info_aspect_impl,
    attr_aspects = ["targets", "test_targets"],
    doc = """
    Retrieves the source files of Java targets with this aspects.
    See SonarProvider
    """,
)

def _get_test_reports(ctx):
    # SonarQube requires test reports to be named like TEST-foo.xml, so we step
    # through `test_targets` to find the matching `test_reports` values, and
    # symlink them to the usable name

    test_targets = getattr(ctx.attr, "test_targets", [])
    test_reports = getattr(ctx.attr, "test_reports", [])

    if not (test_targets and test_reports and ctx.attr.test_reports and ctx.files.test_reports):
        return "", []

    module_path = ctx.build_file_path.replace("/BUILD.bazel", "/").replace("/BUILD", "/")

    test_reports_path = module_path + "test-reports"
    if rule == "sq_project":
        local_test_reports_path = module_path + "test-reports"
    else:
        local_test_reports_path = "test-reports"
    test_reports_runfiles = []

    inc = 0
    for dep in ctx.attr.test_targets:
        if TargetInfo in dep:
            for t in dep[TargetInfo].deps.to_list():
                test_target = t.label
                bazel_test_report_path = "bazel-testlogs/" + test_target.package + "/" + test_target.name + "/test.xml"
                matching_test_reports = [t for t in ctx.files.test_reports if t.short_path == bazel_test_report_path]
                if matching_test_reports:
                    bazel_test_report = matching_test_reports[0]
                    sq_test_report = ctx.actions.declare_file("%s/TEST-%s.xml" % (local_test_reports_path, inc))
                    ctx.actions.symlink(
                        output = sq_test_report,
                        target_file = bazel_test_report,
                    )
                    test_reports_runfiles.append(sq_test_report)
                    inc += 1
                else:
                    fail("Expected Bazel test report for %s with path %s" % (test_target, bazel_test_report_path))

    return test_reports_path, test_reports_runfiles

def _get_coverage_report(ctx, parent_path):
    coverage_report = getattr(ctx.attr, "coverage_report", [])
    if not coverage_report:
        return "", []
    return parent_path + ctx.file.coverage_report.short_path, [ctx.file.coverage_report]

def _test_targets_aspect_impl(target, ctx):
    transitive = []
    direct = []

    if ctx.rule.kind.endswith("_test"):
        direct.append(target)

    if hasattr(ctx.rule.attr, "tests"):
        for dep in ctx.rule.attr.tests:
            transitive.append(dep[TargetInfo].deps)

    return TargetInfo(deps = depset(direct = direct, transitive = transitive))

# This aspect is for collecting test targets from test_suite rules
# to save some duplication in the BUILD files.
test_targets_aspect = aspect(
    implementation = _test_targets_aspect_impl,
    attr_aspects = ["tests"],
)

TargetDepsInfo = provider(
    fields = {
        "deps": "depset of targets",
    },
)

def _test_targets_deps_aspect_impl(_, ctx):
    transitive = []
    direct = []

    if ctx.rule.kind == "jvm_import":
        direct.extend(ctx.rule.attr.jars)
    elif ctx.rule.kind == "java_test":
        for dep in ctx.rule.attr.deps:
            if TargetDepsInfo in dep:
                transitive.append(dep[TargetDepsInfo].deps)
    elif ctx.rule.kind.endswith("_library"):
        pass
    else:
        print("Don't know what to do with %s kind" % ctx.rule.kind)

    return TargetDepsInfo(deps = depset(direct = direct, transitive = transitive))

# This aspect is for collecting test targets dependencies
test_targets_deps_aspect = aspect(
    implementation = _test_targets_deps_aspect_impl,
    attr_aspects = ["deps"],
)


def _get_list_of_unique_files(orig, extra):
    out = []
    for x in orig:
        if type(x) == "File":
            out.append(x)
        else:
            out.extend(x[DefaultInfo].files.to_list())
    out = dict([(x, 1) for x in out])
    for t in extra:
        for f in t[SourceInfo].source_files.to_list():
            out[f] = 1
    return out.keys()

def _get_parent_path(ctx):
    module_path = ctx.build_file_path.replace("/BUILD.bazel", "/").replace("/BUILD", "/")
    depth = len(module_path.split("/")) - 1
    if rule == "sq_project":
        parent_path = "../" * depth
    else:
        parent_path = ""
    return parent_path, module_path, depth

def _build_sonar_project_properties(ctx, sq_properties_file, rule):
    parent_path, _, _ = _get_parent_path(ctx)

    test_reports_path, test_reports_runfiles = _get_test_reports(ctx, parent_path)

    coverage_report_path, coverage_runfiles = _get_coverage_report(ctx, parent_path)

    java_files = _get_java_files([t for t in ctx.attr.targets if t[JavaInfo]])

    srcs = _get_list_of_unique_files(ctx.attr.srcs, ctx.attr.targets)
    test_srcs = _get_list_of_unique_files(ctx.files.test_srcs, ctx.attr.test_targets)

    ctx.actions.expand_template(
        template = ctx.file.sq_properties_template,
        output = sq_properties_file,
        substitutions = {
            "{PROJECT_KEY}": ctx.attr.project_key,
            "{PROJECT_NAME}": ctx.attr.project_name,
            "{SOURCES}": ",".join([parent_path + f.short_path for f in srcs]),
            "{TEST_SOURCES}": ",".join([parent_path + f.short_path for f in test_srcs]),
            "{SOURCE_ENCODING}": ctx.attr.source_encoding,
            "{JAVA_BINARIES}": ",".join([parent_path + j.short_path for j in java_files["output_jars"].to_list()]),
            "{JAVA_LIBRARIES}": ",".join([parent_path + j.short_path for j in java_files["deps_jars"].to_list()]),
            "{MODULES}": ",".join(ctx.attr.modules.values()),
            "{TEST_REPORTS}": test_reports_path,
            "{COVERAGE_REPORT}": coverage_report_path,
            "{EXTRA_ARGUMENTS}": "\n".join([ "%s=%s" % (k, v) for k,v in ctx.attr.extra_arguments.items() ]),
        },
        is_executable = False,
    )

    return ctx.runfiles(
        files = [sq_properties_file] + srcs + test_srcs + test_reports_runfiles + coverage_runfiles,
        transitive_files = depset(transitive = [java_files["output_jars"], java_files["deps_jars"]]),
    )

def _get_java_files(java_targets):
    java_targets = [x[JavaInfo] for x in java_targets]

    return {
        "output_jars": depset(direct = [j for t in java_targets for j in t.runtime_output_jars]),
        "deps_jars": depset(transitive = [t.transitive_runtime_jars for t in java_targets]),
    }

_sonarqube_template = """\
#!/bin/bash

set -euo pipefail

CWD=$(pwd)

TEMPDIR=`mktemp -d -t sonarqube.XXXXXX`
function cleanup {{
    rv=$?
    if [ $rv == 0 ] && [ ! -n "${{SONARQUBE_KEEP_TEMP:-}}" ]; then
        rm -rf $TEMPDIR
    else
        echo "temporary files available at $TEMPDIR"
    fi
    exit $rv
}}
trap cleanup EXIT

pushd $TEMPDIR

cp -rL $CWD/../* .

mkdir -p {workspace_name}/{scm_prefix}

pushd {workspace_name}

rm -rf {scm_basename} 2>/dev/null
cp -r $BUILD_WORKSPACE_DIRECTORY/{scm_path} .

if [[ "{scm_basename}" == ".git" ]]; then
    git update-index --index-version 3
fi

if [[ ! -z "{java_binaries_path}" ]]; then
    mkdir -p {java_binaries_path}
    pushd {java_binaries_path}
    for jar in {java_binaries}; do
        $CWD/{jar_path} -xf "$CWD/$jar"
        rm -rf META-INF
    done
    popd
fi

$CWD/{sonar_scanner} ${{1+"$@"}} \
    -Dproject.settings=$CWD/{sq_properties_file}

popd

echo '... done.'
"""

def _sonarqube_impl(ctx):
    sq_properties_file = ctx.outputs.sq_properties

    local_runfiles = _build_sonar_project_properties(ctx, sq_properties_file, "sonarqube")

    module_runfiles = ctx.runfiles(files = [])
    for module in ctx.attr.modules.keys():
        module_runfiles = module_runfiles.merge(module[DefaultInfo].default_runfiles)

    src_paths = []
    extra_sources = []
    for t in ctx.attr.srcs:
        for f in t[DefaultInfo].files.to_list():
            src_paths.append(f.short_path)
    for t in ctx.attr.targets:
        for f in t[SourceInfo].source_files.to_list():
            src_paths.append(f.short_path)
        extra_sources.extend(t[SourceInfo].source_files.to_list())

    test_src_paths = []
    for t in ctx.attr.test_srcs:
        for f in t[DefaultInfo].files.to_list():
            test_src_paths.append(f.short_path)
    for t in ctx.attr.test_targets:
        for f in t[SourceInfo].source_files.to_list():
            test_src_paths.append(f.short_path)
        extra_sources.extend(t[SourceInfo].source_files.to_list())


    for module in ctx.attr.modules.keys():
        for t in module[SqProjectInfo].srcs:
            for f in t[DefaultInfo].files.to_list():
                src_paths.append(f.short_path)

        for t in module[SqProjectInfo].test_srcs:
            for f in t[DefaultInfo].files.to_list():
                test_src_paths.append(f.short_path)

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = _sonarqube_template.format(
            sq_properties_file = sq_properties_file.short_path,
            sonar_scanner = ctx.executable.sonar_scanner.short_path,
            srcs = " ".join(src_paths),
            test_srcs = " ".join(test_src_paths),
            scm_path = ctx.attr.scm_dir,
            scm_basename = paths.basename(ctx.attr.scm_dir),
            java_binaries_path = "",
            java_binaries = "",
            jdk_path = ""
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [ctx.executable.sonar_scanner] + extra_sources,
        symlinks = ctx.attr.extra_symlinks,
    ).merge(
        ctx.attr.sonar_scanner[DefaultInfo].default_runfiles,
    ).merge(
        local_runfiles,
    ).merge(
        module_runfiles,
    )

    for r in ctx.attr.extra_runfiles:
        runfiles = runfiles.merge(ctx.runfiles(files = r[DefaultInfo].files.to_list()))

    return [DefaultInfo(runfiles = runfiles)]

_COMMON_ATTRS = dict(dict(), **{
    "project_key": attr.string(mandatory = True),
    "project_name": attr.string(),
    "srcs": attr.label_list(allow_files = True, default = []),
    "source_encoding": attr.string(default = "UTF-8"),
    "targets": attr.label_list(default = [], aspects = [source_info_aspect]),
    "modules": attr.label_keyed_string_dict(default = {}),
    "test_srcs": attr.label_list(allow_files = True, default = []),
    "test_targets": attr.label_list(default = [], aspects = [test_targets_aspect, test_targets_deps_aspect, source_info_aspect]),
    "test_reports": attr.label_list(allow_files = True, default = []),
    "sq_properties_template": attr.label(allow_single_file = True, default = "@bazel_sonarqube//:sonar-project.properties.tpl"),
    "sq_properties": attr.output(),
    "extra_symlinks": attr.label_keyed_string_dict(default = {}),
    "extra_runfiles": attr.label_list(default = [], providers = [DefaultInfo], allow_files = True),
    "extra_arguments": attr.string_dict(default = {}),
})

_sonarqube = rule(
    attrs = dict(_COMMON_ATTRS, **{
        "coverage_report": attr.label(allow_single_file = True, mandatory = False),
        "sonar_scanner": attr.label(executable = True, default = "@bazel_sonarqube//:sonar_scanner", cfg = "exec"),
        "scm_dir": attr.string(default = ".git"),
        "scm_prefix": attr.string(default = "."),
    }),
    fragments = ["jvm"],
    host_fragments = ["jvm"],
    implementation = _sonarqube_impl,
    executable = True,
)

def sonarqube(
        name,
        project_key,
        coverage_report = None,
        project_name = None,
        srcs = [],
        source_encoding = None,
        targets = [],
        test_srcs = [],
        test_targets = [],
        test_reports = [],
        modules = {},
        sonar_scanner = "@bazel_sonarqube//:sonar_scanner",
        sq_properties_template = "@bazel_sonarqube//:sonar-project.properties.tpl",
        tags = [],
        visibility = [],
        **kwargs):
    """A runnable rule to execute SonarQube analysis.

    Generates `sonar-project.properties` and invokes the SonarScanner CLI tool
    to perform the analysis.

    Args:
        name: Name of the target.
        project_key: SonarQube project key, e.g. `com.example.project:module`.
        coverage_report: Coverage file in SonarQube generic coverage report
            format. This can be created using the generator from this project
            (see the README for example usage).
        project_name: SonarQube project display name.
        srcs: Project sources to be analysed by SonarQube.
        source_encoding: Source file encoding.
        targets: Bazel targets to be analysed by SonarQube.

            These may be used to provide additional provider information to the
            SQ analysis , e.g. Java classpath context.
        modules: Sub-projects to associate with this SonarQube project, i.e.
            `sq_project` targets.
        test_srcs: Project test sources to be analysed by SonarQube. This must
            be set along with `test_reports` and `test_sources` for accurate
            test reporting.
        test_targets: A list of test targets relevant to the SQ project. This
            will be used with the `test_reports` attribute to generate the
            report paths in sonar-project.properties.
        test_reports: Targets describing Junit-format execution reports. May be
            configured in the workspace root to use Bazel's execution reports
            as below:

            `filegroup(name = "test_reports", srcs = glob(["bazel-testlogs/**/test.xml"]))`


            and referenced as `test_reports = [":test_reports"],`.

            **Note:** this requires manually executing `bazel test` or `bazel
            coverage` before running the `sonarqube` target.
        sonar_scanner: Bazel binary target to execute the SonarQube CLI Scanner.
        sq_properties_template: Template file for `sonar-project.properties`.
        tags: Bazel target tags, e.g. `["manual"]`.
        visibility: Bazel target visibility, e.g. `["//visibility:public"]`.
        **kwargs: other arguments
    """
    _sonarqube(
        name = name,
        project_key = project_key,
        project_name = project_name,
        srcs = srcs,
        source_encoding = source_encoding,
        targets = targets,
        modules = modules,
        test_srcs = test_srcs,
        test_targets = test_targets,
        test_reports = test_reports,
        coverage_report = coverage_report,
        sonar_scanner = sonar_scanner,
        sq_properties_template = sq_properties_template,
        sq_properties = kwargs.pop("sq_properties", "sonar-project.properties"),
        tags = tags,
        visibility = visibility,
        **kwargs
    )

def _sq_project_impl(ctx):
    local_runfiles = _build_sonar_project_properties(ctx, ctx.outputs.sq_properties, "sq_project")

    return [DefaultInfo(
        runfiles = local_runfiles,
    ), SqProjectInfo(
        srcs = ctx.attr.srcs,
        test_srcs = ctx.attr.test_srcs,
    )]

_sq_project = rule(
    attrs = _COMMON_ATTRS,
    implementation = _sq_project_impl,
)

def sq_project(
        name,
        project_key,
        project_name = None,
        srcs = [],
        source_encoding = None,
        targets = [],
        test_srcs = [],
        test_targets = [],
        test_reports = [],
        modules = {},
        sq_properties_template = "@bazel_sonarqube//:sonar-project.properties.tpl",
        tags = [],
        visibility = [],
        **kwargs):
    """A configuration rule to generate SonarQube analysis properties.

    Targets of this type may be referenced by the [`modules`](#sonarqube-modules)
    attribute of the `sonarqube` rule, to create a multi-module SonarQube
    project.

    Args:
        name: Name of the target.
        project_key: SonarQube project key, e.g. `com.example.project:module`.
        project_name: SonarQube project display name.
        srcs: Project sources to be analysed by SonarQube.
        source_encoding: Source file encoding.
        targets: Bazel targets to be analysed by SonarQube.

            These may be used to provide additional provider information to the
            SQ analysis , e.g. Java classpath context.
        modules: Sub-projects to associate with this SonarQube project, i.e.
            `sq_project` targets.
        test_srcs: Project test sources to be analysed by SonarQube. This must
            be set along with `test_reports` and `test_sources` for accurate
            test reporting.
        test_targets: A list of test targets relevant to the SQ project. This
            will be used with the `test_reports` attribute to generate the
            report paths in sonar-project.properties.
        test_reports: Targets describing Junit-format execution reports. May be
            configured in the workspace root to use Bazel's execution reports
            as below:

            `filegroup(name = "test_reports", srcs = glob(["bazel-testlogs/**/test.xml"]))`


            and referenced as `test_reports = [":test_reports"],`.

            **Note:** this requires manually executing `bazel test` or `bazel
            coverage` before running the `sonarqube` target.
        sq_properties_template: Template file for `sonar-project.properties`.
        tags: Bazel target tags, e.g. `["manual"]`.
        visibility: Bazel target visibility, e.g. `["//visibility:public"]`.
    """
    _sq_project(
        name = name,
        project_key = project_key,
        project_name = project_name,
        srcs = srcs,
        test_srcs = test_srcs,
        source_encoding = source_encoding,
        targets = targets,
        test_targets = test_targets,
        test_reports = test_reports,
        modules = modules,
        sq_properties_template = sq_properties_template,
        sq_properties = "sonar-project.properties",
        tags = tags,
        visibility = visibility,
        **kwargs
    )

def _prefixed_path(ctx, path):
    scm_prefix = ctx.attr.scm_prefix

    if scm_prefix:
        scm_prefix = scm_prefix + "/"

    return scm_prefix + ctx.label.package + "/" + path

def _get_target_deps_after_aspect(targets):
    out = []
    for x in targets:
        for y in x[TargetDepsInfo].deps.to_list():
            out.extend(y[DefaultInfo].files.to_list())
    return out

def _sonarqube_maven_style_impl(ctx):
    test_reports_path, _ = _get_test_reports(ctx)

    parent_path, _, _ = _get_parent_path(ctx)

    coverage_report_path, coverage_report_runfiles = _get_coverage_report(ctx, parent_path)

    sq_properties_file = ctx.outputs.sq_properties

    java_files = _get_java_files([t for t in ctx.attr.targets if t[JavaInfo]])

    extra_arguments = dict(ctx.attr.extra_arguments)

    deps = java_files["deps_jars"].to_list()

    test_deps = _get_target_deps_after_aspect(ctx.attr.test_targets)

    ctx.actions.expand_template(
        template = ctx.file.sq_properties_template,
        output = sq_properties_file,
        substitutions = {
            "{COVERAGE_REPORT}": coverage_report_path,
            "{EXTRA_ARGUMENTS}": "\n".join([ "%s=%s" % (k, v) for k,v in extra_arguments.items() ]),
            "{JAVA_BINARIES}": "classes/main",
            "{JAVA_LIBRARIES}": ",".join([j.short_path for j in deps]),
            "{JAVA_TEST_LIBRARIES}": ",".join([j.short_path for j in test_deps]),
            "{MODULES}": ",".join(ctx.attr.modules.values()),
            "{PROJECT_KEY}": ctx.attr.project_key,
            "{PROJECT_NAME}": ctx.attr.project_name,
            "{SOURCE_ENCODING}": ctx.attr.source_encoding,
            "{SOURCES}": _prefixed_path(ctx, ctx.attr.src_path),
            "{TEST_REPORTS}": test_reports_path,
            "{TEST_SOURCES}": _prefixed_path(ctx, ctx.attr.test_path),
        },
        is_executable = False,
    )

    sources = []
    for x in ctx.attr.targets:
        sources.extend(x[SourceInfo].source_files.to_list())

    test_sources = []
    for x in ctx.attr.test_targets:
        test_sources.extend(x[SourceInfo].source_files.to_list())

    java_runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    jar_path = "%s/bin/jar" % java_runtime.java_home

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = _sonarqube_template.format(
            sq_properties_file = sq_properties_file.short_path,
            sonar_scanner = ctx.executable.sonar_scanner.short_path,
            srcs = " ".join([x.short_path for x in sources]),
            test_srcs = " ".join([x.short_path for x in sources]),
            java_binaries_path = "classes/main",
            java_binaries = ",".join([j.short_path for j in java_files["output_jars"].to_list()]),
            scm_path = ctx.attr.scm_dir,
            scm_basename = paths.basename(ctx.attr.scm_dir),
            jar_path = jar_path,
            workspace_name = ctx.label.workspace_name or ctx.workspace_name,
            scm_prefix = ctx.attr.scm_prefix
        ),
        is_executable = True,
    )

    sources = []
    for t in ctx.attr.targets:
        sources.extend(t[DefaultInfo].files.to_list())
        sources.extend(t[SourceInfo].source_files.to_list())

    test_sources = []
    for t in ctx.attr.test_targets:
        test_sources.extend(t[DefaultInfo].files.to_list())
        test_sources.extend(t[SourceInfo].source_files.to_list())

    module_runfiles = ctx.runfiles(files = [])
    for module in ctx.attr.modules.keys():
        module_runfiles = module_runfiles.merge(module[DefaultInfo].default_runfiles)

    runfiles = ctx.runfiles(
        files = [ctx.executable.sonar_scanner, sq_properties_file ] + sources + test_sources + coverage_report_runfiles + deps + test_deps,
        symlinks = ctx.attr.extra_symlinks,
    ).merge(
        ctx.attr.sonar_scanner[DefaultInfo].default_runfiles,
    ).merge(
        module_runfiles,
    )

    for r in ctx.attr.extra_runfiles:
        runfiles = runfiles.merge(ctx.runfiles(files = r[DefaultInfo].files.to_list()))

    return [DefaultInfo(runfiles = runfiles)]

_sonarqube_maven_style_attrs = dict(_COMMON_ATTRS)
_sonarqube_maven_style_attrs.pop("srcs")
_sonarqube_maven_style_attrs.pop("test_srcs")

sonarqube_maven_style = rule(
    implementation = _sonarqube_maven_style_impl,
    attrs = dict(_sonarqube_maven_style_attrs, **{
        "src_path": attr.string(default = "src/main/java"),
        "test_path": attr.string(default = "src/test/java"),
        "coverage_report": attr.label(allow_single_file = True, mandatory = False),
        "sonar_scanner": attr.label(executable = True, default = "@bazel_sonarqube//:sonar_scanner", cfg = "exec"),
        "scm_dir": attr.string(default = ".git"),
        "scm_prefix": attr.string(default = "." ),
        "_jdk": attr.label(
            default = "@bazel_tools//tools/jdk:current_java_runtime",
            providers = [java_common.JavaRuntimeInfo],
            cfg = "exec",
        )
    }),
    executable = True
)
