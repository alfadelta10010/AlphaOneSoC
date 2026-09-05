# conftest.py


def pytest_html_report_title(report):
    report.title = "Generation Report - AAPG"


def pytest_addoption(parser):
    parser.addoption("--configlist", action="store")

    parser.addoption("--seed", action="store")

    parser.addoption("--count", action="store")

    parser.addoption("--output_dir", action="store")

    parser.addoption("--module_dir", action="store")
