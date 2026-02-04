#!/usr/bin/env python3
"""
JudgePay - Conditional USDC Execution for AI Agents
Create tasks, submit work, and evaluate conditions.
"""

import argparse
import json
import os
import hashlib
from web3 import Web3
from eth_account import Account

# Contract addresses (Base Sepolia)
JUDGEPAY_ADDRESS = os.getenv("JUDGEPAY_CONTRACT", "")
USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"

# Default RPC
DEFAULT_RPC = "https://base-sepolia-rpc.publicnode.com"

# Minimal ABIs
USDC_ABI = [
    {
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"}
        ],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [{"name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    },
]

JUDGEPAY_ABI = [
    {
        "inputs": [
            {"name": "_descriptionHash", "type": "bytes32"},
            {"name": "_amount", "type": "uint256"},
            {"name": "_deadlineHours", "type": "uint256"},
            {"name": "_evaluator", "type": "address"},
            {"name": "_minLength", "type": "uint256"},
            {"name": "_maxLength", "type": "uint256"},
            {"name": "_requiredApprovals", "type": "uint8"}
        ],
        "name": "createTask",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [{"name": "_taskId", "type": "uint256"}],
        "name": "claimTask",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [
            {"name": "_taskId", "type": "uint256"},
            {"name": "_outputHash", "type": "bytes32"},
            {"name": "_outputLength", "type": "uint256"}
        ],
        "name": "submitWork",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [
            {"name": "_taskId", "type": "uint256"},
            {"name": "_approve", "type": "bool"}
        ],
        "name": "evaluate",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [{"name": "_taskId", "type": "uint256"}],
        "name": "getTask",
        "outputs": [
            {
                "components": [
                    {"name": "requester", "type": "address"},
                    {"name": "worker", "type": "address"},
                    {"name": "evaluator", "type": "address"},
                    {"name": "amount", "type": "uint256"},
                    {"name": "createdAt", "type": "uint256"},
                    {"name": "deadline", "type": "uint256"},
                    {"name": "descriptionHash", "type": "bytes32"},
                    {"name": "outputHash", "type": "bytes32"},
                    {"name": "status", "type": "uint8"},
                    {"name": "minLength", "type": "uint256"},
                    {"name": "maxLength", "type": "uint256"},
                    {"name": "requiredApprovals", "type": "uint8"},
                    {"name": "currentApprovals", "type": "uint8"}
                ],
                "name": "",
                "type": "tuple"
            }
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "taskCount",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]

# Status mapping
STATUS_NAMES = {
    0: "Open",
    1: "Submitted",
    2: "Completed",
    3: "Refunded",
    4: "Disputed"
}


def get_web3():
    """Get Web3 instance."""
    rpc_url = os.getenv("USDC_RPC_BASE", DEFAULT_RPC)
    return Web3(Web3.HTTPProvider(rpc_url))


def hash_description(description: str) -> bytes:
    """Hash task description."""
    return Web3.keccak(text=description)


def hash_output(output: str) -> bytes:
    """Hash work output."""
    return Web3.keccak(text=output)


def create_task(
    description: str,
    amount_usdc: float,
    deadline_hours: int = 24,
    evaluator: str = None,
    min_length: int = 0,
    max_length: int = 0,
    required_approvals: int = 0,
    private_key: str = None
) -> dict:
    """Create a new task with USDC escrow."""
    
    w3 = get_web3()
    pk = private_key or os.getenv("USDC_PRIVATE_KEY")
    
    if not pk:
        return {"error": "No private key. Set USDC_PRIVATE_KEY."}
    
    if not JUDGEPAY_ADDRESS:
        return {"error": "No contract address. Set JUDGEPAY_CONTRACT."}
    
    account = Account.from_key(pk)
    sender = account.address
    
    # Contracts
    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=USDC_ABI)
    judgepay = w3.eth.contract(address=Web3.to_checksum_address(JUDGEPAY_ADDRESS), abi=JUDGEPAY_ABI)
    
    # Convert amount
    decimals = usdc.functions.decimals().call()
    amount_raw = int(amount_usdc * (10 ** decimals))
    
    # Step 1: Approve USDC
    nonce = w3.eth.get_transaction_count(sender)
    approve_tx = usdc.functions.approve(
        Web3.to_checksum_address(JUDGEPAY_ADDRESS),
        amount_raw
    ).build_transaction({
        'from': sender,
        'nonce': nonce,
        'gas': 100000,
        'gasPrice': w3.eth.gas_price,
        'chainId': w3.eth.chain_id,
    })
    signed = w3.eth.account.sign_transaction(approve_tx, pk)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash)
    
    # Step 2: Create task
    desc_hash = hash_description(description)
    eval_addr = Web3.to_checksum_address(evaluator) if evaluator else "0x0000000000000000000000000000000000000000"
    
    nonce = w3.eth.get_transaction_count(sender)
    create_tx = judgepay.functions.createTask(
        desc_hash,
        amount_raw,
        deadline_hours,
        eval_addr,
        min_length,
        max_length,
        required_approvals
    ).build_transaction({
        'from': sender,
        'nonce': nonce,
        'gas': 300000,
        'gasPrice': w3.eth.gas_price,
        'chainId': w3.eth.chain_id,
    })
    signed = w3.eth.account.sign_transaction(create_tx, pk)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    
    # Get task ID from events or counter
    task_count = judgepay.functions.taskCount().call()
    task_id = task_count - 1
    
    return {
        "success": True,
        "task_id": task_id,
        "description": description,
        "amount_usdc": amount_usdc,
        "deadline_hours": deadline_hours,
        "tx_hash": tx_hash.hex(),
        "explorer": f"https://sepolia.basescan.org/tx/{tx_hash.hex()}"
    }


def get_task(task_id: int) -> dict:
    """Get task details."""
    
    w3 = get_web3()
    
    if not JUDGEPAY_ADDRESS:
        return {"error": "No contract address. Set JUDGEPAY_CONTRACT."}
    
    judgepay = w3.eth.contract(address=Web3.to_checksum_address(JUDGEPAY_ADDRESS), abi=JUDGEPAY_ABI)
    
    task = judgepay.functions.getTask(task_id).call()
    
    return {
        "task_id": task_id,
        "requester": task[0],
        "worker": task[1],
        "evaluator": task[2],
        "amount_usdc": task[3] / 1e6,
        "created_at": task[4],
        "deadline": task[5],
        "description_hash": task[6].hex(),
        "output_hash": task[7].hex(),
        "status": STATUS_NAMES.get(task[8], "Unknown"),
        "min_length": task[9],
        "max_length": task[10],
        "required_approvals": task[11],
        "current_approvals": task[12]
    }


def submit_work(task_id: int, output: str, private_key: str = None) -> dict:
    """Submit work for a task."""
    
    w3 = get_web3()
    pk = private_key or os.getenv("USDC_PRIVATE_KEY")
    
    if not pk:
        return {"error": "No private key. Set USDC_PRIVATE_KEY."}
    
    if not JUDGEPAY_ADDRESS:
        return {"error": "No contract address. Set JUDGEPAY_CONTRACT."}
    
    account = Account.from_key(pk)
    sender = account.address
    
    judgepay = w3.eth.contract(address=Web3.to_checksum_address(JUDGEPAY_ADDRESS), abi=JUDGEPAY_ABI)
    
    output_hash = hash_output(output)
    output_length = len(output)
    
    nonce = w3.eth.get_transaction_count(sender)
    tx = judgepay.functions.submitWork(
        task_id,
        output_hash,
        output_length
    ).build_transaction({
        'from': sender,
        'nonce': nonce,
        'gas': 200000,
        'gasPrice': w3.eth.gas_price,
        'chainId': w3.eth.chain_id,
    })
    signed = w3.eth.account.sign_transaction(tx, pk)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    
    return {
        "success": True,
        "task_id": task_id,
        "output_length": output_length,
        "output_hash": output_hash.hex(),
        "tx_hash": tx_hash.hex(),
        "explorer": f"https://sepolia.basescan.org/tx/{tx_hash.hex()}"
    }


def evaluate_task(task_id: int, approve: bool, private_key: str = None) -> dict:
    """Evaluate submitted work."""
    
    w3 = get_web3()
    pk = private_key or os.getenv("USDC_PRIVATE_KEY")
    
    if not pk:
        return {"error": "No private key. Set USDC_PRIVATE_KEY."}
    
    if not JUDGEPAY_ADDRESS:
        return {"error": "No contract address. Set JUDGEPAY_CONTRACT."}
    
    account = Account.from_key(pk)
    sender = account.address
    
    judgepay = w3.eth.contract(address=Web3.to_checksum_address(JUDGEPAY_ADDRESS), abi=JUDGEPAY_ABI)
    
    nonce = w3.eth.get_transaction_count(sender)
    tx = judgepay.functions.evaluate(
        task_id,
        approve
    ).build_transaction({
        'from': sender,
        'nonce': nonce,
        'gas': 200000,
        'gasPrice': w3.eth.gas_price,
        'chainId': w3.eth.chain_id,
    })
    signed = w3.eth.account.sign_transaction(tx, pk)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    
    return {
        "success": True,
        "task_id": task_id,
        "approved": approve,
        "result": "USDC released to worker" if approve else "USDC refunded to requester",
        "tx_hash": tx_hash.hex(),
        "explorer": f"https://sepolia.basescan.org/tx/{tx_hash.hex()}"
    }


def main():
    parser = argparse.ArgumentParser(description="JudgePay CLI")
    subparsers = parser.add_subparsers(dest="command", help="Commands")
    
    # Create task
    create_parser = subparsers.add_parser("create", help="Create a task")
    create_parser.add_argument("--description", "-d", required=True, help="Task description")
    create_parser.add_argument("--amount", "-a", required=True, type=float, help="USDC amount")
    create_parser.add_argument("--deadline", type=int, default=24, help="Deadline in hours")
    create_parser.add_argument("--evaluator", "-e", help="Evaluator address")
    create_parser.add_argument("--min-length", type=int, default=0, help="Min output length")
    create_parser.add_argument("--max-length", type=int, default=0, help="Max output length")
    
    # Get task
    get_parser = subparsers.add_parser("get", help="Get task details")
    get_parser.add_argument("task_id", type=int, help="Task ID")
    
    # Submit work
    submit_parser = subparsers.add_parser("submit", help="Submit work")
    submit_parser.add_argument("task_id", type=int, help="Task ID")
    submit_parser.add_argument("--output", "-o", required=True, help="Work output")
    
    # Evaluate
    eval_parser = subparsers.add_parser("evaluate", help="Evaluate work")
    eval_parser.add_argument("task_id", type=int, help="Task ID")
    eval_parser.add_argument("--approve", action="store_true", help="Approve work")
    eval_parser.add_argument("--reject", action="store_true", help="Reject work")
    
    args = parser.parse_args()
    
    if args.command == "create":
        result = create_task(
            description=args.description,
            amount_usdc=args.amount,
            deadline_hours=args.deadline,
            evaluator=args.evaluator,
            min_length=args.min_length,
            max_length=args.max_length
        )
    elif args.command == "get":
        result = get_task(args.task_id)
    elif args.command == "submit":
        result = submit_work(args.task_id, args.output)
    elif args.command == "evaluate":
        if args.approve:
            result = evaluate_task(args.task_id, True)
        elif args.reject:
            result = evaluate_task(args.task_id, False)
        else:
            result = {"error": "Specify --approve or --reject"}
    else:
        parser.print_help()
        return
    
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
