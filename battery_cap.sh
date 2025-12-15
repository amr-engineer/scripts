cap=$(cat /sys/class/power_supply/BAT1/capacity)
status=$(cat /sys/class/power_supply/BAT1/status)

if [ $status == "Discharging" ]; then
    bolt=""
else
    bolt="⚡"
fi

echo $cap $bolt
