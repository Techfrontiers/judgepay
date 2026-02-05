import json
from web3 import Web3
import os

# Configuration
RPC_URL = "https://sepolia.base.org"
JUDGEPAY_ADDRESS = Web3.to_checksum_address("0x941bb35BFf8314A20c739EC129d6F38ba73BD4E5")
USDC_ADDRESS = Web3.to_checksum_address("0x036CbD53842c5426634e7929541eC2318f3dCF7e")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY")
MY_ADDRESS = Web3.to_checksum_address("0x4a6a4Db15Ce7C892f62c750fDcC0D34d11572a99")

# ABI
USDC_ABI = [
    {"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"}],"name":"approve","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"}
]

JUDGEPAY_ABI = [
    {"inputs":[{"internalType":"uint96","name":"_amount","type":"uint96"},{"internalType":"uint40","name":"_deadlineHours","type":"uint40"}],"name":"createTask","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"anonymous":False,"inputs":[{"indexed":True,"internalType":"uint256","name":"id","type":"uint256"},{"indexed":True,"internalType":"address","name":"requester","type":"address"},{"indexed":False,"internalType":"uint96","name":"amount","type":"uint96"}],"name":"TaskCreated","type":"event"}
]

def main():
    if not PRIVATE_KEY:
        print("❌ Error: PRIVATE_KEY env var missing")
        return

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print("❌ Error: Cannot connect to RPC")
        return

    print(f"🔗 Connected to Base Sepolia (Block: {w3.eth.block_number})")
    
    usdc = w3.eth.contract(address=USDC_ADDRESS, abi=USDC_ABI)
    judgepay = w3.eth.contract(address=JUDGEPAY_ADDRESS, abi=JUDGEPAY_ABI)
    
    # Check balance
    balance = usdc.functions.balanceOf(MY_ADDRESS).call()
    print(f"💰 USDC Balance: {balance / 10**6} USDC")
    
    # 1. Approve JudgePay to spend USDC
    print("\n[1] Approving JudgePay to spend USDC...")
    approve_amount = 100 * 10**6  # 100 USDC
    
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = usdc.functions.approve(
        JUDGEPAY_ADDRESS,
        approve_amount
    ).build_transaction({
        'chainId': 84532,
        'gas': 100000,
        'gasPrice': w3.eth.gas_price,
        'nonce': nonce
    })
    
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    print(f"✅ Approved! TX: {w3.to_hex(tx_hash)}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"    Confirmed in block {receipt['blockNumber']}")
    
    # 2. Create Task
    print("\n[2] Creating Task: 'AI Content Bounty'...")
    task_amount = 10 * 10**6  # 10 USDC
    print(f"    Budget: 10.00 USDC (REAL)")
    
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = judgepay.functions.createTask(
        task_amount,
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
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"    Confirmed in block {receipt['blockNumber']}")
    
    # Decode Event
    logs = judgepay.events.TaskCreated().process_receipt(receipt)
    if logs:
        task_id = logs[0]['args']['id']
        print(f"🎉 TASK ID: {task_id}")
    
    # Check remaining balance
    balance = usdc.functions.balanceOf(MY_ADDRESS).call()
    print(f"\n💰 Remaining USDC: {balance / 10**6} USDC")
    print(f"🏛️ Contract holds: 10.00 USDC (Escrowed)")

if __name__ == "__main__":
    main()
