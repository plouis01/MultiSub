#!/usr/bin/env python3
"""
ERC-7730 Clear Signing Descriptor Generator

This script analyzes Solidity smart contract source code and generates
ERC-7730 compatible JSON descriptors for Ledger clear signing.

Usage:
    python generate_erc7730.py <contract_file.sol> [options]

Options:
    --chain-id <id>          Chain ID for deployment (default: 1)
    --address <addr>         Contract deployment address (required)
    --output <file>          Output file path (default: calldata-<contract>.json)
    --owner <name>           Owner/entity name (default: extracted from contract)
    --contract-id <id>       Contract identifier (default: contract name)
"""

import re
import json
import sys
import argparse
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
from pathlib import Path


@dataclass
class FunctionParameter:
    """Represents a function parameter"""
    name: str
    type: str

    def get_format(self) -> str:
        """Determine the appropriate display format based on type"""
        # Address types
        if self.type == "address":
            return "addressName"

        # Integer types
        if self.type.startswith("uint") or self.type.startswith("int"):
            # Check for common patterns in parameter names
            if any(x in self.name.lower() for x in ["amount", "value", "balance"]):
                return "tokenAmount"
            elif any(x in self.name.lower() for x in ["timestamp", "time", "deadline"]):
                return "date"
            elif any(x in self.name.lower() for x in ["duration", "period"]):
                return "duration"
            elif any(x in self.name.lower() for x in ["bps", "basis", "percent"]):
                return "raw"
            else:
                return "raw"

        # Bytes types
        if self.type.startswith("bytes"):
            if self.type == "bytes":
                return "calldata"
            return "raw"

        # String types
        if self.type == "string":
            return "raw"

        # Boolean
        if self.type == "bool":
            return "enum"

        # Arrays
        if self.type.endswith("[]"):
            return "raw"

        return "raw"

    def needs_token_path(self) -> bool:
        """Check if this parameter needs a token path"""
        return self.get_format() == "tokenAmount"


@dataclass
class FunctionSignature:
    """Represents a function signature"""
    name: str
    parameters: List[FunctionParameter]
    visibility: str
    natspec: Optional[str] = None

    def get_signature(self) -> str:
        """Generate the full function signature"""
        param_types = [p.type for p in self.parameters]
        return f"{self.name}({','.join(param_types)})"

    def get_intent(self) -> str:
        """Generate a human-readable intent"""
        # Use NatSpec if available
        if self.natspec:
            # Extract first sentence
            match = re.search(r'@notice\s+([^@]+)', self.natspec)
            if match:
                intent = match.group(1).strip()
                # Remove trailing comment markers
                intent = intent.replace('*/', '').replace('*', '').strip()
                # Take first sentence
                intent = intent.split('.')[0].strip()
                if intent:
                    return intent

        # Generate based on function name
        name = self.name

        # Common patterns
        if name.startswith("transfer"):
            return "Transfer tokens"
        elif name.startswith("approve"):
            return "Approve token spending"
        elif name.startswith("execute"):
            return "Execute operation"
        elif name.startswith("deposit"):
            return "Deposit funds"
        elif name.startswith("withdraw"):
            return "Withdraw funds"
        elif name.startswith("swap"):
            return "Swap tokens"
        elif name.startswith("mint"):
            return "Mint tokens"
        elif name.startswith("burn"):
            return "Burn tokens"
        elif name.startswith("grant"):
            return "Grant permissions"
        elif name.startswith("revoke"):
            return "Revoke permissions"
        elif name.startswith("set"):
            return "Update settings"
        elif name.startswith("update"):
            return "Update data"
        elif name.startswith("claim"):
            return "Claim rewards"
        elif name.startswith("stake"):
            return "Stake tokens"
        elif name.startswith("unstake"):
            return "Unstake tokens"

        # Default: capitalize first letter
        return name[0].upper() + name[1:]

    def generate_interpolated_intent(self) -> str:
        """Generate an interpolated intent string"""
        intent = self.get_intent()

        # Add key parameters to the intent
        if len(self.parameters) > 0:
            # Find most important parameters
            important_params = []
            for param in self.parameters:
                if any(x in param.name.lower() for x in ["amount", "value", "to", "recipient", "token"]):
                    important_params.append(param.name)

            if important_params:
                param_str = " ".join([f"{{{p}}}" for p in important_params[:2]])
                intent = f"{intent} {param_str}"

        return intent


class SolidityParser:
    """Parser for Solidity contract files"""

    # Regex patterns
    CONTRACT_PATTERN = re.compile(r'contract\s+(\w+)\s+(?:is\s+)?[{\s]')
    FUNCTION_PATTERN = re.compile(
        r'function\s+(\w+)\s*\((.*?)\)\s*(external|public)',
        re.DOTALL
    )
    PARAM_PATTERN = re.compile(r'(\w+(?:\[\])?)\s+(\w+)')
    NATSPEC_PATTERN = re.compile(r'/\*\*\s*(.*?)\*/', re.DOTALL)

    def __init__(self, file_path: str):
        self.file_path = Path(file_path)
        self.content = self.file_path.read_text()
        self.contract_name: Optional[str] = None
        self.functions: List[FunctionSignature] = []

    def parse(self) -> Tuple[str, List[FunctionSignature]]:
        """Parse the contract file"""
        # Extract contract name
        contract_match = self.CONTRACT_PATTERN.search(self.content)
        if contract_match:
            self.contract_name = contract_match.group(1)
        else:
            raise ValueError("Could not find contract declaration")

        # Extract functions
        self._parse_functions()

        return self.contract_name, self.functions

    def _parse_functions(self):
        """Parse all public/external functions"""
        # Find all functions with their NatSpec comments
        lines = self.content.split('\n')

        for i, line in enumerate(lines):
            # Look for function declarations
            if 'function' in line and ('external' in line or 'public' in line):
                # Try to get NatSpec comment (look backwards)
                natspec = self._get_natspec(lines, i)

                # Get the full function declaration (might span multiple lines)
                func_text = self._get_function_text(lines, i)

                # Parse the function
                func_match = self.FUNCTION_PATTERN.search(func_text)
                if func_match:
                    name = func_match.group(1)
                    params_str = func_match.group(2)
                    visibility = func_match.group(3)

                    # Skip view/pure functions
                    if 'view' in func_text or 'pure' in func_text:
                        continue

                    # Parse parameters
                    parameters = self._parse_parameters(params_str)

                    func_sig = FunctionSignature(
                        name=name,
                        parameters=parameters,
                        visibility=visibility,
                        natspec=natspec
                    )

                    self.functions.append(func_sig)

    def _get_natspec(self, lines: List[str], func_line_idx: int) -> Optional[str]:
        """Extract NatSpec comment for a function"""
        # Look backwards for /** comment
        comment_lines = []
        i = func_line_idx - 1
        in_comment = False

        while i >= 0:
            line = lines[i].strip()

            if line.endswith('*/'):
                in_comment = True
                comment_lines.insert(0, line)
            elif in_comment:
                comment_lines.insert(0, line)
                if line.startswith('/**'):
                    break
            elif line and not line.startswith('//'):
                # Hit non-comment, non-empty line
                break

            i -= 1

        if comment_lines:
            return '\n'.join(comment_lines)
        return None

    def _get_function_text(self, lines: List[str], start_idx: int) -> str:
        """Get the complete function declaration"""
        func_lines = []
        i = start_idx
        paren_count = 0
        started = False

        while i < len(lines):
            line = lines[i]
            func_lines.append(line)

            # Count parentheses to find end of signature
            for char in line:
                if char == '(':
                    paren_count += 1
                    started = True
                elif char == ')':
                    paren_count -= 1

            # Check if we've found the complete signature
            if started and paren_count == 0 and ('{' in line or ';' in line):
                break

            i += 1

        return ' '.join(func_lines)

    def _parse_parameters(self, params_str: str) -> List[FunctionParameter]:
        """Parse function parameters"""
        if not params_str.strip():
            return []

        parameters = []

        # Split by comma (but be careful with nested types)
        param_parts = self._split_parameters(params_str)

        for part in param_parts:
            part = part.strip()
            if not part:
                continue

            # Match type and name - handle arrays and memory/calldata/storage keywords
            # Remove memory/calldata/storage keywords
            part = re.sub(r'\b(memory|calldata|storage)\b', '', part).strip()

            match = self.PARAM_PATTERN.search(part)
            if match:
                param_type = match.group(1)
                param_name = match.group(2)
                parameters.append(FunctionParameter(name=param_name, type=param_type))

        return parameters

    def _split_parameters(self, params_str: str) -> List[str]:
        """Split parameters by comma, respecting nested structures"""
        parts = []
        current = []
        depth = 0

        for char in params_str:
            if char == '(' or char == '[':
                depth += 1
                current.append(char)
            elif char == ')' or char == ']':
                depth -= 1
                current.append(char)
            elif char == ',' and depth == 0:
                parts.append(''.join(current))
                current = []
            else:
                current.append(char)

        if current:
            parts.append(''.join(current))

        return parts


class ERC7730Generator:
    """Generator for ERC-7730 descriptor files"""

    SCHEMA_URL = "https://eips.ethereum.org/assets/eip-7730/erc7730-v1.schema.json"

    def __init__(
        self,
        contract_name: str,
        functions: List[FunctionSignature],
        chain_id: int = 1,
        address: Optional[str] = None,
        owner: Optional[str] = None,
        contract_id: Optional[str] = None
    ):
        self.contract_name = contract_name
        self.functions = functions
        self.chain_id = chain_id
        self.address = address
        self.owner = owner or contract_name
        self.contract_id = contract_id or contract_name

    def generate(self) -> Dict:
        """Generate the complete ERC-7730 descriptor"""
        descriptor = {
            "$schema": self.SCHEMA_URL,
            "context": self._generate_context(),
            "metadata": self._generate_metadata(),
            "display": self._generate_display()
        }

        return descriptor

    def _generate_context(self) -> Dict:
        """Generate the context section"""
        context = {
            "$id": self.contract_id,
            "contract": {
                "deployments": []
            }
        }

        if self.address:
            context["contract"]["deployments"].append({
                "chainId": self.chain_id,
                "address": self.address
            })

        return context

    def _generate_metadata(self) -> Dict:
        """Generate the metadata section"""
        metadata = {
            "owner": self.owner,
            "contractName": self.contract_name,
            "info": {
                "url": "",
                "legalName": self.owner
            }
        }

        # Add enums for boolean types
        enums = {}
        for func in self.functions:
            for param in func.parameters:
                if param.type == "bool":
                    enums["boolean"] = {
                        "0": "False",
                        "1": "True"
                    }
                    break

        if enums:
            metadata["enums"] = enums

        return metadata

    def _generate_display(self) -> Dict:
        """Generate the display section"""
        display = {
            "formats": {}
        }

        for func in self.functions:
            signature = func.get_signature()
            display["formats"][signature] = self._generate_format_for_function(func)

        return display

    def _generate_format_for_function(self, func: FunctionSignature) -> Dict:
        """Generate format specification for a function"""
        format_spec = {
            "intent": func.get_intent(),
            "fields": []
        }

        # Add interpolated intent if there are parameters
        if len(func.parameters) > 0:
            format_spec["interpolatedIntent"] = func.generate_interpolated_intent()

        # Generate field specifications
        for param in func.parameters:
            field = self._generate_field_spec(param, func)
            format_spec["fields"].append(field)

        return format_spec

    def _generate_field_spec(self, param: FunctionParameter, func: FunctionSignature) -> Dict:
        """Generate field specification for a parameter"""
        # Handle array parameters differently
        if param.type.endswith("[]"):
            field = {
                "path": param.name,
                "label": self._generate_label(param),
                "fields": []
            }
            # Arrays need nested field definitions
            # For simplicity, show as raw for now
            return field

        field = {
            "path": param.name,
            "label": self._generate_label(param),
            "format": param.get_format()
        }

        # Add format-specific parameters
        format_type = param.get_format()

        if format_type == "tokenAmount":
            # Try to find token address parameter
            token_param = self._find_token_param(func)
            if token_param:
                field["params"] = {
                    "tokenPath": token_param.name
                }
        elif format_type == "addressName":
            field["params"] = {
                "types": ["eoa", "contract"],
                "sources": ["trust"]
            }
        elif format_type == "enum" and param.type == "bool":
            field["params"] = {
                "enumPath": "$.metadata.enums.boolean"
            }

        return field

    def _generate_label(self, param: FunctionParameter) -> str:
        """Generate a human-readable label for a parameter"""
        # Convert camelCase to Title Case
        name = param.name

        # Handle common abbreviations
        replacements = {
            "bps": "Basis Points",
            "addr": "Address",
            "amt": "Amount",
            "num": "Number",
        }

        for abbr, full in replacements.items():
            if name.lower() == abbr:
                return full

        # Convert camelCase to spaces
        result = re.sub('([A-Z])', r' \1', name)
        return result.strip().title()

    def _find_token_param(self, func: FunctionSignature) -> Optional[FunctionParameter]:
        """Find the token address parameter in a function"""
        for param in func.parameters:
            if param.type == "address" and "token" in param.name.lower():
                return param
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Generate ERC-7730 clear signing descriptors from Solidity contracts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic usage with contract address
  python generate_erc7730.py MyContract.sol --address 0x1234...

  # Specify chain ID and custom output
  python generate_erc7730.py MyContract.sol --address 0x1234... --chain-id 11155111 --output sepolia-mycontract.json

  # Set owner information
  python generate_erc7730.py MyContract.sol --address 0x1234... --owner "My Company"
        """
    )

    parser.add_argument(
        "contract_file",
        help="Path to the Solidity contract file"
    )
    parser.add_argument(
        "--address",
        help="Contract deployment address (required for production use)",
        default=None
    )
    parser.add_argument(
        "--chain-id",
        type=int,
        default=1,
        help="Chain ID for deployment (default: 1 for Ethereum mainnet)"
    )
    parser.add_argument(
        "--output",
        help="Output file path (default: calldata-<contract>.json)"
    )
    parser.add_argument(
        "--owner",
        help="Owner/entity name (default: contract name)"
    )
    parser.add_argument(
        "--contract-id",
        help="Contract identifier (default: contract name)"
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print the JSON output"
    )

    args = parser.parse_args()

    # Parse the contract
    print(f"Parsing contract: {args.contract_file}")
    try:
        sol_parser = SolidityParser(args.contract_file)
        contract_name, functions = sol_parser.parse()
    except Exception as e:
        print(f"Error parsing contract: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Found contract: {contract_name}")
    print(f"Found {len(functions)} public/external state-changing functions")

    # Generate descriptor
    generator = ERC7730Generator(
        contract_name=contract_name,
        functions=functions,
        chain_id=args.chain_id,
        address=args.address,
        owner=args.owner,
        contract_id=args.contract_id
    )

    descriptor = generator.generate()

    # Determine output file
    if args.output:
        output_file = args.output
    else:
        output_file = f"calldata-{contract_name.lower()}.json"

    # Write output
    print(f"Writing descriptor to: {output_file}")
    with open(output_file, 'w') as f:
        if args.pretty:
            json.dump(descriptor, f, indent=2)
        else:
            json.dump(descriptor, f, indent=2)  # Always pretty print for readability

    print("\nGenerated ERC-7730 descriptor successfully!")
    print(f"\nFunction signatures included:")
    for func in functions:
        print(f"  - {func.get_signature()}")

    if not args.address:
        print("\nWARNING: No deployment address specified. Add --address for production use.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
