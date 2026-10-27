#!/bin/bash

cpu_temp=$(sensors | grep 'Core' | awk '{print $3}' | tr -d '+°C' | paste -sd+ | bc -l | awk '{printf "%.1f°C", $1/2}')
gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | awk '{printf "%.1f°C", $1}')

echo "CPU: $cpu_temp | GPU: $gpu_temp"
