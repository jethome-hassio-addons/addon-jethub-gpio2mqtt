![alt text][logo]

# Home Assistant Add-on: JetHome JetHub GPIO2MQTT peripheral exposer

## About

Expose [JetHub](https://jethome.ru) resources (relays, inputs, etc..) to
Home Assistant via [gpio2mqtt](https://github.com/jethome-iot/gpio2mqtt)

This is the next-generation addon: it uses the new gpio2mqtt MQTT topic
structure by default, which changes the entity IDs created in Home Assistant.
It lives alongside the legacy
[jethub-mqtt-io](https://github.com/jethome-hassio-addons/addon-jethub-mqtt-io)
addon — do not run both at the same time, they claim the same GPIO lines.

**Note**: _All used GPIOs will **disappear** from **/sys/class/gpio** during addon run_

**Warning:** The auto-detection option works only on HAOS (Home Assistant Operating System).
For Home Assistant Supervised, please select your device manually in the configuration.

[:books: Read the full add-on documentation][docs]

## Supported devices:

### [JetHome JetHub D1/D1+](https://jethome.ru/d1p) (Basic version with 3 relays, 4 inputs and 1-wire, 1 ZigBee module).

**Exposed peripheral:**

- 3 relays
- 4 inputs
- internal stat LED (green/red)
- (optional) ZigBee module control (BOOT, RESET)

### [JetHome JetHub H1](https://jethome.ru/h1) (Basic version, ZigBee module)

**Exposed peripheral:**

- internal stat LED
- (optional) modules slot control (BOOT, RESET)

### [JetHome JetHub D2](https://jethome.ru/d2) (Basic version with 2 relays, 3 inputs, UXM slots)

**Exposed peripheral:**

- 2 relays
- 3 inputs
- (optional) UXM slots control (BOOT, RESET)

### [JetHome JetHub D3-mini](https://docs.iot.jethome.com) (modular controller, 4 UXM slots)

**Exposed peripheral:**

- UXM slots control (RESET, MODE)

## Installation

Add the repository URL under **Supervisor → Add-on store → ⋮ → Manage add-on repositories**:

    https://github.com/jethome-hassio-addons/repository

# Issues

If you find any issues with the add-on, please check the
[issue tracker](https://github.com/jethome-hassio-addons/addon-jethub-gpio2mqtt/issues)
or similar issues before creating one.

## JetHome resources:

- Documentation - https://docs.jethome.com
- Official website - https://jethome.com
- Telegram news channel - https://t.me/jethome_news
- Telegram english news channel - https://t.me/jethome_iot_news
- Telegram official chat - https://t.me/jethomeru
- Telegram official english chat - https://t.me/jethome_iot
- GitHub: https://github.com/jethome-iot

[docs]: https://github.com/jethome-hassio-addons/addon-jethub-gpio2mqtt/blob/main/jethub-gpio2mqtt/DOCS.md
[logo]: jethub-gpio2mqtt/logo.png "JetHub gpio2mqtt"
