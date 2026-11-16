# Notes for humans

This file is only to be edited by humans.

# App store screenshots

To fake statusbar for screenshots:

```
xcrun simctl status_bar booted override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --operatorName "" \
  --batteryState discharging \
  --batteryLevel 100
```

To restore:

```
xcrun simctl status_bar booted clear
```
