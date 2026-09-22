# conftest.py


def pytest_html_report_title(report):
    report.title = "Generation Report - CTG"


def pytest_addoption(parser):
    parser.addoption("--configfile", action="store")

    parser.addoption("--jobs", action="store")

    parser.addoption("--randomize", action="store_true")

    parser.addoption("--isa", action="store")

    parser.addoption("--output_dir", action="store")

    parser.addoption("--module_dir", action="store")
    
    parser.addoption("--git_branch", action="store")
    
    parser.addoption("--suite", action="store")
    
    parser.addoption("--env", action="store")
