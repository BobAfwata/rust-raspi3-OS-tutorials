#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>

require_relative 'clean_all'
require_relative 'clippy_all'
require_relative 'fmt_all'
require_relative 'make_all'
require_relative 'sanity_checks'
require_relative 'diff_all'

clean_all
fmt_all
system('rubocop -l utils')
sanity_checks
clippy_all

clean_all
make_all
system('cd X1_JTAG_boot && bash update.sh')
diff_all
clean_all
system('~/bin/misspell .')
