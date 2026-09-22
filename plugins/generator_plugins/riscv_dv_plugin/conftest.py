# See LICENSE for details

def pytest_addoption(parser):

    parser.addoption("--riscv_dv_dir", action="store")

    parser.addoption("--target", action="store", default="rv32imac")

    parser.addoption("--isa", action="store")

    parser.addoption("--mabi", action="store")

    parser.addoption("--output_dir", action="store")

    parser.addoption("--testlist", action="store")

    parser.addoption("--seed", action="store", default="")

    parser.addoption("--module_dir", action="store")
