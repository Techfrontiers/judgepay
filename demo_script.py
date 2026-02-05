import json
from web3 import Web3
import os

# Configuration
RPC_URL = "https://sepolia.base.org"
CONTRACT_ADDRESS = Web3.to_checksum_address("0x42B910005890f2ddDAD9eCe12CB9908c5D81F287")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY")
MY_ADDRESS = "0x4a6a4Db15Ce7C892f62c750fDcC0D34d11572a99"

# ABI (Minimal for JudgePayLite)
ABI = [
    {
        "inputs": [
            {"internalType": "uint96", "name": "_amount", "type": "uint96"},
            {"internalType": "uint40", "name": "_deadlineHours", "type": "uint40"}
        ],
        "name": "createTask",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "internalType": "uint256", "name": "id", "type": "uint256"},
            {"indexed": True, "internalType": "address", "name": "requester", "type": "address"},
            {"indexed": False, "internalType": "uint96", "name": "amount", "type": "uint96"}
        ],
        "name": "TaskCreated",
        "type": "event"
    }
]

def main():
    if not PRIVATE_KEY:
        print("Error: PRIVATE_KEY env var missing")
        return

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print("Error: Cannot connect to RPC")
        return

    print(f"🔗 Connected to Base Sepolia (Block: {w3.eth.block_number})")
    
    contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=ABI)
    
    # 1. Create Task
    print("\n[1] Creating Task: 'Cyberpunk Content Bounty'...")
    amount_usdc = 50 * 10**6  # 50 USDC
    print(f"    Budget: 50.00 USDC")
    
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = contract.functions.createTask(
        amount_usdc,
        24  # 24 hours deadline
    ).build_transaction({
        'chainId': 84532,
        'gas': 200000,
        'gasPrice': w3.eth.gas_price,
        'nonce': nonce
    })
    
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    
    print(f"✅ Task Created! TX: {w3.to_hex(tx_hash)}")
    print("    Waiting for confirmation...")
    
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"    Confirmed in block {receipt['blockNumber']}")
    
    # Decode Event to get Task ID
    logs = contract.events.TaskCreated().process_receipt(receipt)
    if logs:
        task_id = logs[0]['args']['id']
        print(f"🎉 TASK ID: {task_id}")
    else:
        print("⚠️ Warning: No TaskCreated event found")

if __name__ == "__main__":
    main()
