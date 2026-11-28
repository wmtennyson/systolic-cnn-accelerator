# Makefile for running cocotb tests

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = $(wildcard ./verilog/*.sv) $(wildcard ./verilog/*.v)

COCOTB_TOPLEVEL = core

COCOTB_TEST_MODULES = testbench

COCOTB_HDL_TIMEPRECISION = 1ns

WAVES = 1

include $(shell cocotb-config --makefiles)/Makefile.sim