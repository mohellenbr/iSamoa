# Sam(oa)² - SFCs and Adaptive Meshes for Oceanic And Other Applications
# Copyright (C) 2010 Oliver Meister, Kaveh Rahnema
# This program is licensed under the GPL, for details see the file LICENSE


#!/bin/bash

cpus=$(lscpu | grep "^CPU(s)" | grep -oE "[0-9]+" | tr "\n" " ")
output_dir=output/$(date +"%Y-%m-%d_%H-%M-%S")_OpenMP_Scaling
script_dir=$(dirname $0)

mkdir -p $output_dir
mkdir -p scripts

echo "CPU(s) detected : "$cpus
echo "Output directory: "$output_dir
echo ""
echo "Running scenarios..."

limit=02:00:00

for asagimode in 2
do
	for sections in 8
	do
		for processes in 1
		do
			for threads in 10 20 40
			do
				nodes=$(( ($processes * $threads - 1) / 40 + 1 ))

				script="scripts/run_p"$processes"_t"$threads"_s"$sections"_a"$asagimode".sh"
				cat run_supzero_test.sh > $script

				sed -i 's=$asagimode='$asagimode'=g' $script
				sed -i 's=$sections='$sections'=g' $script
				sed -i 's=$processes='$processes'=g' $script
				sed -i 's=$threads='$threads'=g' $script
				sed -i 's=$output_dir='$output_dir'=g' $script
				sed -i 's=$nodes='$nodes'=g' $script
				sed -i 's=$limit='$limit'=g' $script

				llsubmit $script
			done
		done
	done
done

