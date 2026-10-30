#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6.0"]
# ///
"""
GPIO Unexport Script for gpio2mqtt

This script reads a gpio2mqtt configuration file, identifies all configured
GPIO pins, and unexports them from sysfs (/sys/class/gpio/) if they are
currently exported.

This is useful when switching from sysfs-based GPIO control to gpiod/gpiocdev,
as sysfs exports can block access to GPIO lines via the character device.

Usage:
    sudo ./gpio-unexport.py config.yaml
    sudo ./gpio-unexport.py --dry-run config.yaml
    sudo uv run gpio-unexport.py config.yaml
"""

import argparse
import fcntl
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)

# Root of the sysfs tree; overridable for testing
SYSFS_ROOT = Path(os.environ.get("GPIO_UNEXPORT_SYSFS_ROOT", "/sys"))

# struct gpiochip_info { char name[32]; char label[32]; __u32 lines; }
# _IOWR(0xB4, 0x01, 68) — stable GPIO uAPI v1 ioctl
_GPIO_GET_CHIPINFO_IOCTL = 0xC044B401


def get_chip_label(chip_path: str) -> str | None:
    """Read the character device chip label via the GPIO uAPI ioctl."""
    try:
        fd = os.open(chip_path, os.O_RDONLY | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        buf = bytearray(68)
        fcntl.ioctl(fd, _GPIO_GET_CHIPINFO_IOCTL, buf, True)
        label = bytes(buf[32:64]).split(b"\0")[0].decode(errors="replace")
        return label or None
    except OSError:
        return None
    finally:
        os.close(fd)


def get_gpiochip_base(chip_path: str) -> int | None:
    """
    Get the base GPIO number for a gpiochip.

    Maps /dev/gpiochipN to the corresponding sysfs gpiochip entry.
    The sysfs entries are named by their base number (e.g., gpiochip512),
    not by the /dev device number.
    """
    sysfs_path = find_sysfs_gpiochip(chip_path)
    if sysfs_path:
        base_file = sysfs_path / "base"
        if base_file.exists():
            return int(base_file.read_text().strip())

    return None


def find_sysfs_gpiochip(chip_path: str) -> Path | None:
    """Find the sysfs path for a /dev/gpiochipN device."""
    chip_name = os.path.basename(chip_path)
    if not chip_name.startswith("gpiochip"):
        print(f"Warning: Invalid chip path: {chip_path}")
        return None

    dev_chip_path = SYSFS_ROOT / "bus/gpio/devices" / chip_name

    # Method 1: on recent kernels (6.x) the device symlink resolves directly
    # into the legacy sysfs chip directory, which contains `base`
    if dev_chip_path.exists():
        try:
            resolved = dev_chip_path.resolve()
            if (resolved / "base").exists():
                return resolved
        except OSError:
            pass

        # Method 2: legacy layout — a gpio/gpiochip* subdirectory next to
        # the resolved device
        try:
            gpio_subdir = resolved.parent / "gpio"
            if gpio_subdir.exists():
                for gpio_dir in gpio_subdir.glob("gpiochip*"):
                    if (gpio_dir / "base").exists():
                        return gpio_dir
        except OSError:
            pass

    # Method 3: match by chardev device number (major:minor)
    try:
        dev_stat = os.stat(chip_path)
        dev_major_minor = (os.major(dev_stat.st_rdev), os.minor(dev_stat.st_rdev))

        devices = SYSFS_ROOT / "bus/gpio/devices"
        for entry in devices.iterdir() if devices.is_dir() else []:
            if not entry.name.startswith("gpiochip"):
                continue
            dev_file = entry / "dev"
            if not dev_file.exists():
                continue
            try:
                major, minor = map(int, dev_file.read_text().strip().split(":"))
            except (OSError, ValueError):
                continue
            if (major, minor) != dev_major_minor:
                continue
            gpio_subdir = entry.resolve().parent / "gpio"
            if gpio_subdir.exists():
                for gpio_dir in gpio_subdir.glob("gpiochip*"):
                    if (gpio_dir / "base").exists():
                        return gpio_dir
    except OSError:
        pass

    # Method 4: match the chardev chip label (read via the GPIO uAPI ioctl)
    # against /sys/class/gpio/gpiochip*/label
    label = get_chip_label(chip_path)
    if label:
        class_gpio = SYSFS_ROOT / "class/gpio"
        for entry in class_gpio.iterdir() if class_gpio.is_dir() else []:
            if not entry.name.startswith("gpiochip"):
                continue
            label_file = entry / "label"
            try:
                if label_file.exists() and label_file.read_text().strip() == label:
                    return entry
            except OSError:
                continue

    return None


def get_gpiochip_info(chip_path: str) -> dict:
    """Get information about a gpiochip from sysfs."""
    chip_name = os.path.basename(chip_path)

    info = {
        "name": chip_name,
        "path": chip_path,
        "base": None,
        "ngpio": None,
        "label": None,
        "sysfs_name": None,
    }

    sysfs_path = find_sysfs_gpiochip(chip_path)
    if sysfs_path:
        info["sysfs_name"] = sysfs_path.name
        base_file = sysfs_path / "base"
        ngpio_file = sysfs_path / "ngpio"
        label_file = sysfs_path / "label"

        if base_file.exists():
            info["base"] = int(base_file.read_text().strip())
        if ngpio_file.exists():
            info["ngpio"] = int(ngpio_file.read_text().strip())
        if label_file.exists():
            info["label"] = label_file.read_text().strip()

    return info


def is_gpio_exported(gpio_num: int) -> bool:
    """Check if a GPIO is currently exported in sysfs."""
    return (SYSFS_ROOT / "class/gpio" / f"gpio{gpio_num}").exists()


def unexport_gpio(gpio_num: int, dry_run: bool = False) -> bool:
    """Unexport a GPIO from sysfs."""
    unexport_path = SYSFS_ROOT / "class/gpio/unexport"

    if dry_run:
        print(f"  [DRY-RUN] Would unexport GPIO {gpio_num}")
        return True

    try:
        unexport_path.write_text(str(gpio_num))
        print(f"  Unexported GPIO {gpio_num}")
        return True
    except PermissionError:
        print("  Error: Permission denied. Run with sudo.")
        return False
    except OSError as e:
        print(f"  Error unexporting GPIO {gpio_num}: {e}")
        return False


def parse_config(config_path: str) -> dict:
    """Parse gpio2mqtt YAML configuration file."""
    with open(config_path) as f:
        return yaml.safe_load(f)


def collect_gpios_from_config(config: dict) -> list[dict]:
    """
    Collect all GPIO pins from configuration.

    Returns list of dicts with: name, module, pin, chip_path
    """
    gpios = []

    # Build module -> chip mapping
    modules = {}
    for module in config.get("gpio_modules", []):
        modules[module["name"]] = module.get("chip", "/dev/gpiochip0")

    # Collect digital inputs
    for input_cfg in config.get("digital_inputs", []):
        module_name = input_cfg.get("module", "")
        chip_path = modules.get(module_name, "/dev/gpiochip0")
        pin = input_cfg.get("pin")
        if pin is not None:
            gpios.append(
                {
                    "name": input_cfg.get("name", f"input_{pin}"),
                    "module": module_name,
                    "pin": int(pin),
                    "chip_path": chip_path,
                    "type": "input",
                }
            )

    # Collect digital outputs
    for output_cfg in config.get("digital_outputs", []):
        module_name = output_cfg.get("module", "")
        chip_path = modules.get(module_name, "/dev/gpiochip0")
        pin = output_cfg.get("pin")
        if pin is not None:
            gpios.append(
                {
                    "name": output_cfg.get("name", f"output_{pin}"),
                    "module": module_name,
                    "pin": int(pin),
                    "chip_path": chip_path,
                    "type": "output",
                }
            )

    return gpios


def main():
    parser = argparse.ArgumentParser(
        description="Unexport GPIOs from sysfs based on gpio2mqtt config"
    )
    parser.add_argument("config", help="Path to gpio2mqtt configuration file")
    parser.add_argument(
        "--dry-run",
        "-n",
        action="store_true",
        help="Show what would be done without actually unexporting",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show detailed information"
    )
    args = parser.parse_args()

    # Check config file exists
    if not os.path.exists(args.config):
        print(f"Error: Config file not found: {args.config}")
        sys.exit(1)

    # Parse configuration
    print(f"Reading configuration from: {args.config}")
    config = parse_config(args.config)

    # Collect all GPIOs
    gpios = collect_gpios_from_config(config)
    if not gpios:
        print("No GPIO pins found in configuration")
        sys.exit(0)

    print(f"Found {len(gpios)} GPIO pins in configuration\n")

    # Group by chip
    chips = {}
    for gpio in gpios:
        chip_path = gpio["chip_path"]
        if chip_path not in chips:
            chips[chip_path] = {
                "info": get_gpiochip_info(chip_path),
                "gpios": [],
            }
        chips[chip_path]["gpios"].append(gpio)

    # Process each chip
    unexported_count = 0
    skipped_count = 0
    error_count = 0

    for chip_path, chip_data in chips.items():
        chip_info = chip_data["info"]
        print(f"GPIO Chip: {chip_path}")

        if chip_info["base"] is None:
            sysfs_active = (SYSFS_ROOT / "class/gpio/unexport").exists()
            if sysfs_active:
                # Loud failure: sysfs exports can hold the configured lines
                # and gpio2mqtt would fail with EBUSY — never pass silently
                offsets = sorted(gpio["pin"] for gpio in chip_data["gpios"])
                print(f"  ERROR: could not determine the sysfs base for {chip_path},")
                print("  but the sysfs GPIO interface is active. Lines exported via")
                print("  sysfs cannot be used by gpiod and gpio2mqtt will fail with")
                print(f"  'Device or resource busy'. Configured line offsets: {offsets}")
                print("  Find the global numbers with: cat /sys/kernel/debug/gpio")
                print("  and unexport them on the host:")
                print("    echo <N> > /sys/class/gpio/unexport")
                error_count += 1
            else:
                print(f"  Warning: Could not determine base for {chip_path}")
                print("  (sysfs interface may not be available)")
            continue

        if args.verbose:
            if chip_info["sysfs_name"]:
                print(f"  sysfs: {chip_info['sysfs_name']}")
            print(f"  Base: {chip_info['base']}")
            print(f"  Lines: {chip_info['ngpio']}")
            if chip_info["label"]:
                print(f"  Label: {chip_info['label']}")

        print()

        for gpio in chip_data["gpios"]:
            line_offset = gpio["pin"]
            gpio_num = chip_info["base"] + line_offset
            name = gpio["name"]

            print(f"  {name} (line {line_offset} -> GPIO {gpio_num}):")

            if is_gpio_exported(gpio_num):
                if unexport_gpio(gpio_num, args.dry_run):
                    unexported_count += 1
                else:
                    error_count += 1
            else:
                print("    Not exported, skipping")
                skipped_count += 1

        print()

    # Summary
    print("=" * 40)
    print("Summary:")
    print(f"  Unexported: {unexported_count}")
    print(f"  Skipped (not exported): {skipped_count}")
    if error_count > 0:
        print(f"  Errors: {error_count}")

    if args.dry_run:
        print("\n[DRY-RUN mode - no changes were made]")

    if error_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
