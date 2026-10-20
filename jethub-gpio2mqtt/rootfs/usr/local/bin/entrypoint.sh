#!/bin/bash
# shellcheck disable=SC1091
# entrypoint.sh - Main entrypoint for JetHome peripheral exposer addon
#
# Startup sequence:
# 1. Read options from /data/options.json
# 2. Detect JetHub model (if auto)
# 3. Get MQTT settings (auto-discover or manual)
# 4. Generate final config
# 5. Run gpio-unexport.py
# 6. Start gpio2mqtt

set -euo pipefail

# Configuration paths
OPTIONS_FILE="/data/options.json"
CONFIGS_DIR="/etc/gpio2mqtt/configs"
GENERATED_CONFIG="/data/gpio2mqtt.yaml"
GPIO_UNEXPORT_SCRIPT="/etc/gpio2mqtt/gpio-unexport.py"

# Logging functions
log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    if [[ "${LOG_LEVEL:-info}" == "debug" || "${LOG_LEVEL:-info}" == "trace" ]]; then
        echo "[DEBUG] $*"
    fi
}

# Read option from options.json
get_option() {
    local key="$1"
    local default="${2:-}"
    local value
    value=$(jq -r ".$key // empty" "$OPTIONS_FILE" 2>/dev/null || echo "")
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Get nested option
get_nested_option() {
    local key="$1"
    local default="${2:-}"
    local value
    value=$(jq -r ".$key // empty" "$OPTIONS_FILE" 2>/dev/null || echo "")
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Discover MQTT settings from Home Assistant Supervisor API
discover_mqtt() {
    log_info "Discovering MQTT settings from Home Assistant..."

    if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
        log_error "SUPERVISOR_TOKEN not available, cannot auto-discover MQTT"
        return 1
    fi

    local mqtt_info
    mqtt_info=$(curl -sSL -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/services/mqtt" 2>/dev/null || echo "{}")

    if [[ "$mqtt_info" == "{}" ]] || ! echo "$mqtt_info" | jq -e '.data' >/dev/null 2>&1; then
        log_error "Failed to get MQTT info from Supervisor API"
        return 1
    fi

    MQTT_HOST=$(echo "$mqtt_info" | jq -r '.data.host // empty')
    MQTT_PORT=$(echo "$mqtt_info" | jq -r '.data.port // empty')
    MQTT_USER=$(echo "$mqtt_info" | jq -r '.data.username // empty')
    MQTT_PASS=$(echo "$mqtt_info" | jq -r '.data.password // empty')

    # Validate MQTT host was discovered
    if [[ -z "$MQTT_HOST" ]]; then
        log_error "MQTT host not found in Supervisor API response"
        log_error "Please configure MQTT broker in Home Assistant or provide manual MQTT settings"
        return 1
    fi

    log_info "Discovered MQTT: host=$MQTT_HOST, port=$MQTT_PORT, user=$MQTT_USER"
}

# Guard: refuse to start while the legacy jethub-mqtt-io addon is running.
# Both addons claim the same GPIO lines; the second one would just crash
# with cryptic gpiod errors. Fail-open if the Supervisor API is not usable
# (e.g. fully manual MQTT setup without supervisor access).
check_legacy_addon() {
    if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
        log_info "No Supervisor token, skipping legacy addon check"
        return 0
    fi

    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/info" 2>/dev/null) || {
        log_info "Supervisor API not reachable, skipping legacy addon check"
        return 0
    }

    if ! echo "$response" | jq -e '.result == "ok"' >/dev/null 2>&1; then
        log_info "Supervisor info not available, skipping legacy addon check"
        return 0
    fi

    local legacy_state
    legacy_state=$(echo "$response" | jq -r \
        '.data.addons[]? | select(.slug == "jethub-mqtt-io") | .state' 2>/dev/null)

    case "$legacy_state" in
        started|startup)
            log_error "The legacy jethub-mqtt-io add-on is currently running."
            log_error "Both add-ons claim the same GPIO lines and cannot run at the same time."
            log_error "Stop and disable the jethub-mqtt-io add-on, then start this add-on."
            return 1
            ;;
        "")
            log_info "Legacy jethub-mqtt-io add-on not installed - OK"
            ;;
        *)
            log_info "Legacy jethub-mqtt-io add-on state: $legacy_state - OK"
            ;;
    esac
    return 0
}

# Generate final configuration
generate_config() {
    local base_config="$1"
    local output_config="$2"

    log_info "Generating config from: $base_config"

    # Check for whitespace-only custom config
    local trimmed_config
    trimmed_config=$(echo "${CUSTOM_CONFIG:-}" | tr -d '[:space:]')

    # Start with base config or custom config
    if [[ -n "$trimmed_config" ]]; then
        log_info "Using custom config from addon options"
        echo "$CUSTOM_CONFIG" > "$output_config"
    else
        cp "$base_config" "$output_config"
    fi

    # Export variables for Python script (avoids shell injection)
    export GPIO2MQTT_CONFIG_PATH="$output_config"
    export GPIO2MQTT_MQTT_HOST="$MQTT_HOST"
    export GPIO2MQTT_MQTT_PORT="$MQTT_PORT"
    export GPIO2MQTT_MQTT_USER="$MQTT_USER"
    export GPIO2MQTT_MQTT_PASS="$MQTT_PASS"
    export GPIO2MQTT_MQTT_CLIENT_ID="$MQTT_CLIENT_ID"
    export GPIO2MQTT_MQTT_TOPIC_PREFIX="$MQTT_TOPIC_PREFIX"
    export GPIO2MQTT_MQTT_LEGACY_MQTTIO="$MQTT_LEGACY_MQTTIO"
    export GPIO2MQTT_MQTT_KEEPALIVE="$MQTT_KEEPALIVE"
    export GPIO2MQTT_MQTT_QOS="$MQTT_QOS"
    export GPIO2MQTT_RESTORE_MODE="$RESTORE_MODE"

    # Update MQTT settings using Python (more reliable YAML handling)
    python3 << 'PYTHON_EOF'
import os
import yaml
import sys

# Custom Loader that treats on/off/yes/no as strings, not booleans (YAML 1.1 compat)
# This prevents PyYAML from converting "off" to False
class SafeLoaderNoYAML11Bool(yaml.SafeLoader):
    pass

# Remove implicit resolvers for YAML 1.1 boolean values (on/off/yes/no)
# Keep only true/false as booleans
for ch in list('OoYyNn'):
    if ch in SafeLoaderNoYAML11Bool.yaml_implicit_resolvers:
        SafeLoaderNoYAML11Bool.yaml_implicit_resolvers[ch] = [
            (tag, regexp) for tag, regexp in SafeLoaderNoYAML11Bool.yaml_implicit_resolvers[ch]
            if tag != 'tag:yaml.org,2002:bool'
        ]

# Custom Dumper that quotes strings that look like YAML booleans
# This ensures "off"/"on" stay as strings and aren't reinterpreted
class SafeDumperPreserveStrings(yaml.SafeDumper):
    pass

YAML_BOOL_STRINGS = {'true', 'false', 'yes', 'no', 'on', 'off', 'y', 'n'}

def str_representer(dumper, value):
    # Quote strings that could be interpreted as booleans
    if value.lower() in YAML_BOOL_STRINGS:
        return dumper.represent_scalar('tag:yaml.org,2002:str', value, style="'")
    return dumper.represent_scalar('tag:yaml.org,2002:str', value)

SafeDumperPreserveStrings.add_representer(str, str_representer)

config_path = os.environ.get('GPIO2MQTT_CONFIG_PATH', '')
mqtt_host = os.environ.get('GPIO2MQTT_MQTT_HOST', '')
mqtt_port = os.environ.get('GPIO2MQTT_MQTT_PORT', '')
mqtt_user = os.environ.get('GPIO2MQTT_MQTT_USER', '')
mqtt_pass = os.environ.get('GPIO2MQTT_MQTT_PASS', '')
mqtt_client_id = os.environ.get('GPIO2MQTT_MQTT_CLIENT_ID', '')
mqtt_topic_prefix = os.environ.get('GPIO2MQTT_MQTT_TOPIC_PREFIX', '')
mqtt_legacy_mqttio = os.environ.get('GPIO2MQTT_MQTT_LEGACY_MQTTIO', 'false')
mqtt_keepalive = os.environ.get('GPIO2MQTT_MQTT_KEEPALIVE', '')
mqtt_qos = os.environ.get('GPIO2MQTT_MQTT_QOS', '')
restore_mode = os.environ.get('GPIO2MQTT_RESTORE_MODE', '')

try:
    with open(config_path, 'r') as f:
        config = yaml.load(f, Loader=SafeLoaderNoYAML11Bool)

    if config is None:
        config = {}

    if 'mqtt' not in config:
        config['mqtt'] = {}

    # Update MQTT settings - always set host, delete user/pass if empty (anonymous auth)
    if mqtt_host:
        config['mqtt']['host'] = mqtt_host
    if mqtt_port:
        config['mqtt']['port'] = int(mqtt_port)

    # Handle user/password - delete if empty for anonymous auth
    if mqtt_user:
        config['mqtt']['user'] = mqtt_user
    elif 'user' in config['mqtt']:
        del config['mqtt']['user']

    if mqtt_pass:
        config['mqtt']['password'] = mqtt_pass
    elif 'password' in config['mqtt']:
        del config['mqtt']['password']

    if mqtt_client_id:
        config['mqtt']['client_id'] = mqtt_client_id
    if mqtt_topic_prefix:
        config['mqtt']['topic_prefix'] = mqtt_topic_prefix
    if mqtt_keepalive:
        config['mqtt']['keepalive'] = int(mqtt_keepalive)
    if mqtt_qos:
        config['mqtt']['qos'] = int(mqtt_qos)

    # Set legacy_mqttio boolean
    config['mqtt']['legacy_mqttio'] = mqtt_legacy_mqttio.lower() == 'true'

    # Apply the addon-level restore_mode to outputs that don't define their
    # own restore_mode/restore_state (the two keys are mutually exclusive in
    # gpio2mqtt and setting both is rejected at startup)
    if restore_mode:
        for output in config.get('digital_outputs') or []:
            if isinstance(output, dict) and 'restore_mode' not in output and 'restore_state' not in output:
                output['restore_mode'] = restore_mode

    with open(config_path, 'w') as f:
        yaml.dump(config, f, Dumper=SafeDumperPreserveStrings, default_flow_style=False, allow_unicode=True)

    print("[INFO] Config updated successfully")
except Exception as e:
    print(f"[ERROR] Failed to update config: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
}

# Run GPIO unexport script
run_gpio_unexport() {
    local config_file="$1"

    if [[ -f "$GPIO_UNEXPORT_SCRIPT" ]]; then
        log_info "Running GPIO unexport script..."
        python3 "$GPIO_UNEXPORT_SCRIPT" "$config_file" || {
            log_error "GPIO unexport failed, continuing anyway..."
        }
    else
        log_info "GPIO unexport script not found, skipping..."
    fi
}

# Resolve the /dev/gpiochipN path of the TCA6408A UXM port expander (JetHub D3).
# The expander sits on I2C (address 0x21); its gpiochip number depends on
# driver probe order, so it is looked up via sysfs: i2c client named "tca6408"
# -> matching /sys/class/gpiochipN device link.
resolve_tca6408_chip() {
    if [[ -n "${GPIO2MQTT_TCA6408_CHIP:-}" ]]; then
        echo "${GPIO2MQTT_TCA6408_CHIP#/dev/}"
        return 0
    fi

    local client_dir client gpiochip
    for client_dir in /sys/bus/i2c/devices/*/; do
        [[ -f "${client_dir}name" ]] || continue
        if [[ "$(cat "${client_dir}name" 2>/dev/null)" == "tca6408" ]]; then
            client=$(readlink -f "$client_dir")
            for gpiochip in /sys/class/gpiochip*/; do
                [[ -e "${gpiochip}device" ]] || continue
                if [[ "$(readlink -f "${gpiochip}device")" == "$client" ]]; then
                    basename "${gpiochip%/}"
                    return 0
                fi
            done
        fi
    done
    return 1
}

# Substitute the __TCA6408__ chip placeholder in the generated config
substitute_d3_chip() {
    local config_file="$1"

    if ! grep -q "__TCA6408__" "$config_file"; then
        return 0
    fi

    log_info "Resolving TCA6408 UXM expander gpiochip..."
    local chip
    if ! chip=$(resolve_tca6408_chip); then
        log_error "TCA6408 port expander not found (no i2c client 'tca6408' with a gpiochip)"
        log_error "Check that the expander is enabled in the device tree,"
        log_error "or provide the full config with the chip path via custom_config"
        return 1
    fi

    sed -i "s|__TCA6408__|/dev/$chip|g" "$config_file"
    log_info "UXM expander chip resolved to: /dev/$chip"
}

# Main function
main() {
    log_info "Starting JetHome peripheral exposer addon..."

    # Check options file
    if [[ ! -f "$OPTIONS_FILE" ]]; then
        log_error "Options file not found: $OPTIONS_FILE"
        exit 1
    fi

    # Read options
    LOG_LEVEL=$(get_option "log_level" "info")
    JETHUB_MODEL=$(get_option "jethub_model" "auto")
    USE_MODULE_CONFIG=$(get_option "use_module_config" "false")
    CUSTOM_CONFIG=$(get_option "custom_config" "")
    RESTORE_MODE=$(get_option "restore_mode" "restore")
    MQTT_CLIENT_ID=$(get_nested_option "mqtt.client_id" "jethub-gpio2mqtt")
    MQTT_TOPIC_PREFIX=$(get_nested_option "mqtt.topic_prefix" "jethub-gpio2mqtt")
    MQTT_LEGACY_MQTTIO=$(get_nested_option "mqtt.legacy_mqttio" "false")

    # Manual MQTT settings (optional)
    MANUAL_MQTT_HOST=$(get_nested_option "mqtt.host" "")
    MANUAL_MQTT_PORT=$(get_nested_option "mqtt.port" "")
    MANUAL_MQTT_USER=$(get_nested_option "mqtt.user" "")
    MANUAL_MQTT_PASS=$(get_nested_option "mqtt.password" "")

    # Advanced MQTT settings
    MQTT_KEEPALIVE=$(get_nested_option "mqtt.keepalive" "60")
    MQTT_QOS=$(get_nested_option "mqtt.qos" "1")

    log_info "Options: model=$JETHUB_MODEL, use_module=$USE_MODULE_CONFIG, log_level=$LOG_LEVEL"

    # Refuse to start while the legacy jethub-mqtt-io addon is running
    check_legacy_addon || exit 1

    # Check for whitespace-only custom config (used in multiple places)
    local trimmed_custom_config
    trimmed_custom_config=$(echo "${CUSTOM_CONFIG:-}" | tr -d '[:space:]')

    # Validate manual mode - custom_config is required
    if [[ "$JETHUB_MODEL" == "manual" ]]; then
        if [[ -z "$trimmed_custom_config" ]]; then
            log_error "Manual mode requires custom_config to be set"
            log_error "Please provide a complete gpio2mqtt YAML configuration in the custom_config field"
            exit 1
        fi
        log_info "Using manual mode with custom configuration"
        # For manual mode, BASE_CONFIG is not used, but we set a dummy value
        BASE_CONFIG=""
    else
        # Detect model if auto
        if [[ "$JETHUB_MODEL" == "auto" ]]; then
            log_info "Auto-detecting JetHub model..."
            # Source the detect-model script
            source /usr/local/bin/detect-model.sh
            JETHUB_MODEL=$(detect_model) || {
                log_error "Failed to detect JetHub model"
                exit 1
            }
            log_info "Detected model: $JETHUB_MODEL"
        fi

        # Determine base config file
        if [[ "$USE_MODULE_CONFIG" == "true" ]]; then
            BASE_CONFIG="${CONFIGS_DIR}/${JETHUB_MODEL}-module.yaml"
            if [[ ! -f "$BASE_CONFIG" ]]; then
                log_info "No module config for ${JETHUB_MODEL}, using base config"
                BASE_CONFIG="${CONFIGS_DIR}/${JETHUB_MODEL}.yaml"
            fi
        else
            BASE_CONFIG="${CONFIGS_DIR}/${JETHUB_MODEL}.yaml"
        fi

        # Check if base config exists (only if no valid custom config)
        if [[ -z "$trimmed_custom_config" ]]; then
            if [[ ! -f "$BASE_CONFIG" ]]; then
                log_error "Base config not found: $BASE_CONFIG"
                log_error "Available configs:"
                ls -la "$CONFIGS_DIR/" || true
                exit 1
            fi
        fi
    fi

    # Get MQTT settings
    MQTT_HOST=""
    MQTT_PORT=""
    MQTT_USER=""
    MQTT_PASS=""

    # Use manual settings if provided, otherwise auto-discover
    if [[ -n "$MANUAL_MQTT_HOST" ]]; then
        log_info "Using manual MQTT settings"
        MQTT_HOST="$MANUAL_MQTT_HOST"
        MQTT_PORT="${MANUAL_MQTT_PORT:-1883}"
        MQTT_USER="$MANUAL_MQTT_USER"
        MQTT_PASS="$MANUAL_MQTT_PASS"
    else
        log_info "Auto-discovering MQTT settings..."
        discover_mqtt || {
            log_error "MQTT auto-discovery failed and no manual settings provided"
            exit 1
        }
    fi

    # Generate final config
    generate_config "$BASE_CONFIG" "$GENERATED_CONFIG"

    # Resolve the D3 UXM expander chip placeholder (no-op for other models)
    substitute_d3_chip "$GENERATED_CONFIG"

    # Run GPIO unexport
    run_gpio_unexport "$GENERATED_CONFIG"

    # Start gpio2mqtt
    log_info "Starting gpio2mqtt..."

    # Set log level for Rust application
    case "$LOG_LEVEL" in
        trace)
            export RUST_LOG="trace"
            ;;
        debug)
            export RUST_LOG="debug"
            ;;
        info)
            export RUST_LOG="info"
            ;;
        warning)
            export RUST_LOG="warn"
            ;;
        error)
            export RUST_LOG="error"
            ;;
        *)
            export RUST_LOG="info"
            ;;
    esac

    # Execute gpio2mqtt (replace this process)
    exec /usr/local/bin/gpio2mqtt --config "$GENERATED_CONFIG"
}

# Run main
main "$@"
