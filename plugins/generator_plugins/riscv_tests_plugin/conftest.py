# conftest.py


def pytest_html_report_title(report):
    report.title = "Generation Report - RISCV-TESTS"


def pytest_addoption(parser):

    parser.addoption("--output_dir", action="store")
    parser.addoption("--module_dir", action="store")
