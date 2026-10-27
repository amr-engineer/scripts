#!/bin/bash

cpu_temp="CPU: $(sensors | grep 'Core' | awk '{print $3}' | tr -d '+°C' | paste -sd+ | bc -l | awk '{printf "%.1f°C", $1/2}')"

gpu_temp=""
if command -v nvidia-smi &> /dev/null; then
	gpu_temp="| GPU: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | awk '{printf "%.1f°C", $1}')"
fi

echo "$cpu_temp $gpu_temp"
