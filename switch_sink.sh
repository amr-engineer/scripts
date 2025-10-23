#!/bin/bash

CURRENT_SINK=$(pactl get-default-sink)

SINKS=($(pactl list short sinks | awk '{print $2}'))

for i in "${!SINKS[@]}"; do
   if [[ "${SINKS[$i]}" == "$CURRENT_SINK" ]]; then
      CURRENT_INDEX=$i
   fi
done

NEXT_INDEX=$(( (CURRENT_INDEX + 1) % ${#SINKS[@]} ))

pactl set-default-sink "${SINKS[$NEXT_INDEX]}"

pactl list short sink-inputs | awk '{print $1}' | while read -r STREAM; do
   pactl move-sink-input "$STREAM" "${SINKS[$NEXT_INDEX]}"
done

echo "Switched to sink: ${SINKS[$NEXT_INDEX]}"
