#!/usr/bin/env python3
"""
ERC-7730 Descriptor Validator

Validates generated ERC-7730 JSON files against the official schema.
Can also check for common issues and best practices.

Usage:
    python validate_erc7730.py <descriptor.json> [--strict]
"""

import json
import sys
import argparse
from pathlib import Path
from typing import Dict, List, Tuple


class ERC7730Validator:
    """Validator for ERC-7730 descriptor files"""

    REQUIRED_FIELDS = {
        "root": ["$schema", "context", "display"],
        "context": ["$id"],
        "display": ["formats"]
    }

    def __init__(self, descriptor_path: str, strict: bool = False):
        self.descriptor_path = Path(descriptor_path)
        self.strict = strict
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.info: List[str] = []

    def validate(self) -> bool:
        """Run all validations"""
        print(f"Validating: {self.descriptor_path}")
        print("=" * 60)

        # Load file
        try:
            with open(self.descriptor_path) as f:
                self.descriptor = json.load(f)
        except FileNotFoundError:
            self.errors.append(f"File not found: {self.descriptor_path}")
            return False
        except json.JSONDecodeError as e:
            self.errors.append(f"Invalid JSON: {e}")
            return False

        # Run checks
        self._check_structure()
        self._check_schema_url()
        self._check_context()
        self._check_metadata()
        self._check_display()
        self._check_best_practices()

        # Print results
        self._print_results()

        return len(self.errors) == 0

    def _check_structure(self):
        """Validate overall structure"""
        for field in self.REQUIRED_FIELDS["root"]:
            if field not in self.descriptor:
                self.errors.append(f"Missing required field: {field}")

    def _check_schema_url(self):
        """Check schema URL"""
        expected = "https://eips.ethereum.org/assets/eip-7730/erc7730-v1.schema.json"
        actual = self.descriptor.get("$schema")

        if actual != expected:
            self.errors.append(
                f"Incorrect schema URL.\n"
                f"  Expected: {expected}\n"
                f"  Got: {actual}"
            )

    def _check_context(self):
        """Validate context section"""
        context = self.descriptor.get("context", {})

        # Check required fields
        if "$id" not in context:
            self.errors.append("Missing context.$id")

        # Check contract or eip712
        if "contract" not in context and "eip712" not in context:
            self.errors.append("Context must have either 'contract' or 'eip712'")

        # Check deployments
        if "contract" in context:
            contract = context["contract"]
            deployments = contract.get("deployments", [])

            if len(deployments) == 0:
                self.warnings.append("No deployments specified in context.contract")
            else:
                for i, deployment in enumerate(deployments):
                    if "chainId" not in deployment:
                        self.errors.append(f"Deployment {i} missing chainId")
                    if "address" not in deployment:
                        self.errors.append(f"Deployment {i} missing address")
                    else:
                        addr = deployment["address"]
                        if addr == "0x0000000000000000000000000000000000000000":
                            self.warnings.append(
                                f"Deployment {i} uses zero address (placeholder)"
                            )
                        if not addr.startswith("0x") or len(addr) != 42:
                            self.errors.append(
                                f"Deployment {i} has invalid address format: {addr}"
                            )

    def _check_metadata(self):
        """Validate metadata section"""
        metadata = self.descriptor.get("metadata", {})

        if not metadata:
            self.warnings.append("No metadata section (optional but recommended)")
            return

        # Check for useful metadata
        if "owner" not in metadata:
            self.warnings.append("metadata.owner not specified")

        if "contractName" not in metadata:
            self.warnings.append("metadata.contractName not specified")

        # Check info
        info = metadata.get("info", {})
        if not info.get("url"):
            self.info.append("Consider adding metadata.info.url")

        # Check for token metadata if tokenAmount formats exist
        if self._has_token_amount_formats() and "token" not in metadata:
            self.info.append(
                "Functions use tokenAmount format. "
                "Consider adding metadata.token with name, ticker, decimals"
            )

    def _check_display(self):
        """Validate display section"""
        display = self.descriptor.get("display", {})

        if "formats" not in display:
            self.errors.append("Missing display.formats")
            return

        formats = display["formats"]

        if len(formats) == 0:
            self.warnings.append("No formats defined in display.formats")
            return

        self.info.append(f"Found {len(formats)} function format(s)")

        # Validate each format
        for sig, format_def in formats.items():
            self._check_format(sig, format_def)

    def _check_format(self, signature: str, format_def: Dict):
        """Validate a single format definition"""
        # Check intent
        if "intent" not in format_def:
            self.errors.append(f"{signature}: Missing 'intent'")

        # Check fields
        if "fields" not in format_def:
            self.warnings.append(f"{signature}: Missing 'fields' array")
            return

        fields = format_def["fields"]

        for i, field in enumerate(fields):
            self._check_field(signature, i, field)

    def _check_field(self, signature: str, index: int, field: Dict):
        """Validate a field definition"""
        field_id = f"{signature} field[{index}]"

        # Check required properties
        if "path" not in field:
            self.errors.append(f"{field_id}: Missing 'path'")

        if "format" not in field and "fields" not in field:
            self.errors.append(
                f"{field_id}: Must have either 'format' or 'fields' (for containers)"
            )

        # Check format-specific requirements
        fmt = field.get("format")

        if fmt == "tokenAmount":
            params = field.get("params", {})
            if "tokenPath" not in params:
                self.info.append(
                    f"{field_id}: tokenAmount without tokenPath parameter. "
                    "Consider linking to token address parameter"
                )

        if fmt == "addressName":
            params = field.get("params", {})
            if "types" not in params:
                self.info.append(
                    f"{field_id}: addressName without 'types' parameter"
                )

        if fmt == "enum":
            params = field.get("params", {})
            if "enumPath" not in params:
                self.errors.append(
                    f"{field_id}: enum format requires 'enumPath' parameter"
                )

    def _check_best_practices(self):
        """Check for best practices"""
        # Check for interpolated intents
        formats = self.descriptor.get("display", {}).get("formats", {})

        for sig, format_def in formats.items():
            if "interpolatedIntent" not in format_def and len(format_def.get("fields", [])) > 0:
                self.info.append(
                    f"{sig}: Consider adding 'interpolatedIntent' for better UX"
                )

        # Check for labels
        for sig, format_def in formats.items():
            for field in format_def.get("fields", []):
                if "label" not in field and "format" in field:
                    self.warnings.append(
                        f"{sig}: Field '{field.get('path', '?')}' missing label"
                    )

    def _has_token_amount_formats(self) -> bool:
        """Check if any formats use tokenAmount"""
        formats = self.descriptor.get("display", {}).get("formats", {})

        for format_def in formats.values():
            for field in format_def.get("fields", []):
                if field.get("format") == "tokenAmount":
                    return True

        return False

    def _print_results(self):
        """Print validation results"""
        print()

        if self.errors:
            print(f"❌ ERRORS ({len(self.errors)}):")
            for error in self.errors:
                print(f"  • {error}")
            print()

        if self.warnings:
            print(f"⚠️  WARNINGS ({len(self.warnings)}):")
            for warning in self.warnings:
                print(f"  • {warning}")
            print()

        if self.info and self.strict:
            print(f"ℹ️  SUGGESTIONS ({len(self.info)}):")
            for info in self.info:
                print(f"  • {info}")
            print()

        if not self.errors:
            if not self.warnings or not self.strict:
                print("✅ Validation passed!")
            else:
                print("✅ Validation passed (with warnings)")
        else:
            print("❌ Validation failed")

        print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Validate ERC-7730 descriptor files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic validation
  python validate_erc7730.py calldata-mycontract.json

  # Strict mode (show all suggestions)
  python validate_erc7730.py calldata-mycontract.json --strict

  # Validate multiple files
  python validate_erc7730.py calldata-*.json
        """
    )

    parser.add_argument(
        "files",
        nargs="+",
        help="ERC-7730 descriptor file(s) to validate"
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Enable strict mode (show all suggestions)"
    )

    args = parser.parse_args()

    # Validate each file
    all_passed = True

    for file_path in args.files:
        validator = ERC7730Validator(file_path, args.strict)
        passed = validator.validate()

        if not passed:
            all_passed = False

        if len(args.files) > 1:
            print()  # Separator between files

    # Exit code
    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
