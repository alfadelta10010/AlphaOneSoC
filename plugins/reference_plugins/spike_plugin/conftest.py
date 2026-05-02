# conftest.py
import pytest
from py.xml import html


def pytest_html_report_title(report):
    report.title = "Reference Report - Spike"


def pytest_addoption(parser):
    parser.addoption("--make_file", action="store")
    parser.addoption("--work_dir", action="store")
    parser.addoption("--key_list", action="store")


# i.e. a new column for getting the stage,
# Need to figure out a way to get the 2nd argument passed to item.function


# The internal error for timeout caused of these hooks :|
@pytest.mark.optionalhook
def pytest_html_results_table_header(cells):
    cells.insert(1, html.th('Stage'))


@pytest.mark.optionalhook
def pytest_html_results_table_row(report, cells):
    cells.insert(1, html.td(report.ticket))


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    report.ticket = str(item.funcargs['test_input'][-1]) if 'test_input' in item.funcargs else 'N/A'
