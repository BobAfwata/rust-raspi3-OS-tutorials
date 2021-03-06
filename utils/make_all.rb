#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>

require_relative 'helpers/tutorial_folders.rb'

def make_all(bsp = 'rpi3')
    crates = tutorial_folders

    crates.each do |x|
        x = File.dirname(x)
        puts "\n\n" + x.to_s + "\n\n"
        Dir.chdir(x) do
            unless system("BSP=#{bsp} make")
                puts "\n\nBuild failed!"
                exit(1) # Exit with error code
            end
        end
    end
end

make_all(ARGV[0]) if $PROGRAM_NAME == __FILE__
